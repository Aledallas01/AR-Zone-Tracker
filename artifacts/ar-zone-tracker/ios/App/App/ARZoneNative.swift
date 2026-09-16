import ARKit
import AudioToolbox
import Capacitor
import CoreHaptics
import Foundation
import SceneKit
import UIKit

@objc(ARZoneNative)
public class ARZoneNative: CAPPlugin, CAPBridgedPlugin, ARSessionDelegate, ARSCNViewDelegate,
    UIGestureRecognizerDelegate {
    public let identifier = "ARZoneNative"
    public let jsName = "ARZoneNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isSupported", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "placeZone", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "previewZone", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resetSession", returnType: CAPPluginReturnPromise),
    ]

    // Azzurro scuro per il volume, spigoli piu scuri e spessi.
    private let zoneFillColor = UIColor(red: 0.09, green: 0.33, blue: 0.58, alpha: 1)
    private let zoneEdgeColor = UIColor(red: 0.02, green: 0.12, blue: 0.27, alpha: 1)
    private let scanMeshColor = UIColor(red: 0.42, green: 0.78, blue: 1, alpha: 1)

    private let arSession = ARSession()
    private var arView: ARSCNView?
    private var zoneAnchor: ARAnchor?
    private var zonePlaneAnchorID: UUID?
    private var zoneRelativeTransform = matrix_identity_float4x4
    private var zoneNode: SCNNode?
    private var zoneTransform = matrix_identity_float4x4
    private var zoneIsPlaced = false
    private var horizontalPlaneDetected = false
    private var zoneWidth: Float = 0.2
    private var zoneDepth: Float = 0.1
    private var zoneHeight: Float = 0.05
    private var currentZoneState = ""
    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticPatternPlayer?

    /// Nodi della mesh LiDAR, uno per ARMeshAnchor. Mostrati solo finche la zona
    /// non e posizionata: servono a far vedere che la scansione sta avvenendo.
    private var meshNodes: [UUID: SCNNode] = [:]
    private var showsScanMesh = true

    /// Anteprima del volume prima della conferma: segue il centro dello schermo
    /// cosi si vede esattamente dove finira il box.
    private var previewNode: SCNNode?
    private var previewTransform: simd_float4x4?
    private var previewPlaneAnchorID: UUID?
    private var showsPreview = true

    /// Quote sui lati, accese e spente con un doppio tap sul box.
    private var dimensionsVisible = false

    override public func load() {
        super.load()
        arSession.delegate = self
        prepareHaptics()
    }

    @objc func isSupported(_ call: CAPPluginCall) {
        let supported = ARWorldTrackingConfiguration.isSupported
        let lidarAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        call.resolve([
            "supported": supported,
            "lidarAvailable": lidarAvailable,
        ])
    }

    @objc func startSession(_ call: CAPPluginCall) {
        guard ARWorldTrackingConfiguration.isSupported else {
            call.reject("ARWorldTracking non e supportato su questo iPhone.")
            return
        }

        // Clamp a 1 cm: un minimo piu alto alzerebbe in silenzio le quote piccole.
        zoneWidth = max(0.01, Float(call.getDouble("width") ?? 0.2))
        zoneDepth = max(0.01, Float(call.getDouble("depth") ?? 0.1))
        zoneHeight = max(0.01, Float(call.getDouble("height") ?? 0.05))
        clearZone()
        showsScanMesh = true
        showsPreview = true

        let configuration = ARWorldTrackingConfiguration()
        // Anche i piani verticali: piu ancore stabili in scena significa meno
        // deriva, non servono solo a poggiarci sopra la zona.
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isAutoFocusEnabled = true

        let lidarAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        if lidarAvailable {
            // La scansione vera e propria: ARKit ricostruisce una mesh
            // dell'ambiente e la usa come riferimento geometrico per il
            // tracking, invece dei soli punti caratteristici della camera.
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                call.reject("Impossibile inizializzare la sessione ARKit.")
                return
            }

            guard self.showCameraPreview() else {
                call.reject("Impossibile mostrare la fotocamera ARKit.")
                return
            }
            self.arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            call.resolve([
                "started": true,
                "lidarAvailable": lidarAvailable,
            ])
        }
    }

    /// Conferma la posizione mostrata dall'anteprima. Si usa la trasformazione
    /// gia mostrata a schermo, non una nuova: cosi il box finisce esattamente
    /// dove l'utente lo stava vedendo.
    @objc func placeZone(_ call: CAPPluginCall) {
        guard let transform = previewTransform else {
            call.reject("Nessuna superficie inquadrata. Punta il centro dello schermo verso il pavimento.")
            return
        }

        let planeID = previewPlaneAnchorID
        clearZone()
        zoneTransform = transform
        zoneIsPlaced = true
        showsPreview = false
        showsScanMesh = false
        removeScanMesh()
        hidePreview()

        if let planeID,
           let planeAnchor = arSession.currentFrame?.anchors.first(where: {
               $0.identifier == planeID
           }) as? ARPlaneAnchor {
            // Caso migliore: la zona diventa figlia del piano rilevato. ARKit
            // raffina di continuo posizione ed estensione dei piani, e la zona
            // segue quelle correzioni invece di restare indietro.
            zonePlaneAnchorID = planeAnchor.identifier
            zoneRelativeTransform = simd_mul(simd_inverse(planeAnchor.transform), transform)
            attachZoneToPlane(planeAnchor)
        } else {
            // Nessun piano sotto il raycast: ancora libera, comunque corretta da
            // ARKit a ogni ri-localizzazione.
            let anchor = ARAnchor(name: "arZone", transform: transform)
            zoneAnchor = anchor
            arSession.add(anchor: anchor)
        }

        call.resolve(["placed": true])
    }

    /// Torna in anteprima senza fermare la sessione: la zona posizionata sparisce
    /// e il box torna a seguire il centro dello schermo.
    @objc func previewZone(_ call: CAPPluginCall) {
        clearZone()
        showsPreview = true
        call.resolve(["preview": true])
    }

    @objc func resetSession(_ call: CAPPluginCall) {
        clearZone()
        showsPreview = true
        showsScanMesh = true
        arSession.pause()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.arView?.removeFromSuperview()
            self.arView = nil
            self.bridge?.webView?.isOpaque = true
            self.bridge?.webView?.backgroundColor = nil
        }
        call.resolve()
    }

    private func clearZone() {
        if let anchor = zoneAnchor {
            arSession.remove(anchor: anchor)
        }
        zoneAnchor = nil
        zonePlaneAnchorID = nil
        zoneRelativeTransform = matrix_identity_float4x4
        DispatchQueue.main.async { [weak self] in
            self?.zoneNode?.removeFromParentNode()
            self?.zoneNode = nil
        }
        zoneIsPlaced = false
        horizontalPlaneDetected = false
        currentZoneState = ""
    }

    private func showCameraPreview() -> Bool {
        guard arView == nil, let viewController = bridge?.viewController else { return false }

        let sceneView = ARSCNView(frame: viewController.view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.session = arSession
        sceneView.delegate = self
        sceneView.scene = SCNScene()
        sceneView.backgroundColor = .clear
        sceneView.rendersCameraGrain = true
        sceneView.automaticallyUpdatesLighting = true
        viewController.view.insertSubview(sceneView, at: 0)
        viewController.view.backgroundColor = .clear
        bridge?.webView?.isOpaque = false
        bridge?.webView?.backgroundColor = .clear
        bridge?.webView?.scrollView.backgroundColor = .clear
        // ARSCNView puo prendersi la delega della sessione quando gliela si
        // assegna: la riprendiamo, altrimenti gli eventi di frame non arrivano.
        arSession.delegate = self
        arView = sceneView

        // La webview copre tutto lo schermo, quindi i tocchi non arrivano mai
        // alla scena: il riconoscitore va messo sulla webview, senza rubarle
        // gli eventi, e il test 3D si fa convertendo le coordinate.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        (bridge?.webView ?? viewController.view).addGestureRecognizer(doubleTap)

        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let sceneView = arView, let zone = zoneNode else { return }
        let point = gesture.location(in: sceneView)
        let hits = sceneView.hitTest(point, options: [
            SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue,
        ])
        let touchedZone = hits.contains { hit in
            var node: SCNNode? = hit.node
            while let current = node {
                if current === zone { return true }
                node = current.parent
            }
            return false
        }
        guard touchedZone else { return }

        dimensionsVisible.toggle()
        zone.childNode(withName: "dimensions", recursively: false)?.isHidden = !dimensionsVisible
    }

    // MARK: - Anteprima del posizionamento

    /// Trasformazione del box a partire dal centro dello schermo: raycast sulla
    /// geometria gia rilevata e orientamento preso dalla direzione della camera.
    private func placementTarget(in sceneView: ARSCNView, frame: ARFrame) -> (simd_float4x4, UUID?)? {
        let screenCenter = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        var hit: ARRaycastResult?
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            if hit != nil { break }
            if let query = sceneView.raycastQuery(
                from: screenCenter,
                allowing: target,
                alignment: .horizontal
            ) {
                hit = arSession.raycast(query).first
            }
        }
        guard let result = hit else { return nil }

        let camera = frame.camera.transform
        let forward = SIMD3<Float>(-camera.columns.2.x, 0, -camera.columns.2.z)
        let forwardLength = simd_length(forward)
        guard forwardLength > 0.001 else { return nil }

        let normalizedForward = forward / forwardLength
        let right = SIMD3<Float>(normalizedForward.z, 0, -normalizedForward.x)

        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(right.x, 0, right.z, 0)
        transform.columns.1 = SIMD4<Float>(0, 1, 0, 0)
        transform.columns.2 = SIMD4<Float>(-normalizedForward.x, 0, -normalizedForward.z, 0)
        transform.columns.3 = result.worldTransform.columns.3

        return (transform, (result.anchor as? ARPlaneAnchor)?.identifier)
    }

    private func updatePreview(in sceneView: ARSCNView) {
        guard showsPreview, !zoneIsPlaced else {
            hidePreview()
            return
        }
        guard let frame = arSession.currentFrame,
              frame.camera.trackingState == .normal,
              let (transform, planeID) = placementTarget(in: sceneView, frame: frame) else {
            previewTransform = nil
            previewPlaneAnchorID = nil
            previewNode?.isHidden = true
            return
        }

        previewTransform = transform
        previewPlaneAnchorID = planeID

        let node: SCNNode
        if let existing = previewNode {
            node = existing
        } else {
            node = buildZoneNode()
            node.opacity = 0.55
            sceneView.scene.rootNode.addChildNode(node)
            previewNode = node
        }
        node.isHidden = false
        node.simdTransform = transform
    }

    private func hidePreview() {
        previewTransform = nil
        previewPlaneAnchorID = nil
        DispatchQueue.main.async { [weak self] in
            self?.previewNode?.removeFromParentNode()
            self?.previewNode = nil
        }
    }

    // MARK: - Mesh della scansione

    /// Converte la geometria di un ARMeshAnchor in una SCNGeometry disegnabile.
    private func scanGeometry(from meshAnchor: ARMeshAnchor) -> SCNGeometry {
        let mesh = meshAnchor.geometry
        let vertices = mesh.vertices
        let faces = mesh.faces

        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: vertices.format,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
        )
        let faceData = Data(
            bytes: faces.buffer.contents(),
            count: faces.buffer.length
        )
        let element = SCNGeometryElement(
            data: faceData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: faces.bytesPerIndex
        )

        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.fillMode = .lines
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.diffuse.contents = scanMeshColor.withAlphaComponent(0.55)
        material.emission.contents = scanMeshColor.withAlphaComponent(0.35)
        geometry.materials = [material]
        return geometry
    }

    private func removeScanMesh() {
        let nodes = meshNodes
        meshNodes.removeAll()
        DispatchQueue.main.async {
            nodes.values.forEach { $0.removeFromParentNode() }
        }
    }

    private func attachZoneToPlane(_ planeAnchor: ARPlaneAnchor) {
        guard let sceneView = arView else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let planeNode = sceneView.node(for: planeAnchor) else { return }
            let zone = self.buildZoneNode()
            zone.simdTransform = self.zoneRelativeTransform
            planeNode.addChildNode(zone)
            self.zoneNode = zone
        }
    }

    // MARK: - Geometria del volume

    private func buildZoneNode() -> SCNNode {
        let container = SCNNode()
        let width = CGFloat(zoneWidth)
        let height = CGFloat(zoneHeight)
        let depth = CGFloat(zoneDepth)
        let centerY = zoneHeight / 2

        let fillMaterial = SCNMaterial()
        fillMaterial.lightingModel = .constant
        fillMaterial.isDoubleSided = true
        fillMaterial.writesToDepthBuffer = false
        fillMaterial.diffuse.contents = zoneFillColor.withAlphaComponent(0.30)
        fillMaterial.emission.contents = zoneFillColor.withAlphaComponent(0.16)
        let fillBox = SCNBox(width: width, height: height, length: depth, chamferRadius: 0)
        fillBox.materials = [fillMaterial]
        let fillNode = SCNNode(geometry: fillBox)
        fillNode.position = SCNVector3(0, centerY, 0)
        fillNode.renderingOrder = 10
        container.addChildNode(fillNode)

        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .constant
        floorMaterial.isDoubleSided = true
        floorMaterial.writesToDepthBuffer = false
        floorMaterial.diffuse.contents = zoneEdgeColor.withAlphaComponent(0.35)
        let floorPlane = SCNPlane(width: width, height: depth)
        floorPlane.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floorPlane)
        floorNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        floorNode.position = SCNVector3(0, 0.002, 0)
        floorNode.renderingOrder = 9
        container.addChildNode(floorNode)

        // Spigoli come barrette solide invece di fillMode = .lines: le linee di
        // SceneKit sono sempre spesse un pixel, qui lo spessore e reale.
        let edgeMaterial = SCNMaterial()
        edgeMaterial.lightingModel = .constant
        edgeMaterial.isDoubleSided = true
        edgeMaterial.diffuse.contents = zoneEdgeColor
        edgeMaterial.emission.contents = zoneEdgeColor.withAlphaComponent(0.55)

        let smallest = min(zoneWidth, min(zoneDepth, zoneHeight))
        let thickness = max(0.004, smallest * 0.09)
        let halfX = zoneWidth / 2
        let halfY = zoneHeight / 2
        let halfZ = zoneDepth / 2

        for sy in [-1, 1] as [Float] {
            for sz in [-1, 1] as [Float] {
                container.addChildNode(edgeNode(
                    size: SCNVector3(zoneWidth + thickness, thickness, thickness),
                    position: SCNVector3(0, centerY + sy * halfY, sz * halfZ),
                    material: edgeMaterial
                ))
            }
        }
        for sx in [-1, 1] as [Float] {
            for sz in [-1, 1] as [Float] {
                container.addChildNode(edgeNode(
                    size: SCNVector3(thickness, zoneHeight + thickness, thickness),
                    position: SCNVector3(sx * halfX, centerY, sz * halfZ),
                    material: edgeMaterial
                ))
            }
        }
        for sx in [-1, 1] as [Float] {
            for sy in [-1, 1] as [Float] {
                container.addChildNode(edgeNode(
                    size: SCNVector3(thickness, thickness, zoneDepth + thickness),
                    position: SCNVector3(sx * halfX, centerY + sy * halfY, 0),
                    material: edgeMaterial
                ))
            }
        }

        let dimensions = buildDimensionLabels(thickness: thickness)
        dimensions.name = "dimensions"
        dimensions.isHidden = !dimensionsVisible
        container.addChildNode(dimensions)

        return container
    }

    private func edgeNode(size: SCNVector3, position: SCNVector3, material: SCNMaterial) -> SCNNode {
        let box = SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: 0
        )
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.position = position
        node.renderingOrder = 11
        return node
    }

    // MARK: - Quote

    private func buildDimensionLabels(thickness: Float) -> SCNNode {
        let group = SCNNode()
        let margin = thickness * 3
        let halfX = zoneWidth / 2
        let halfY = zoneHeight / 2
        let halfZ = zoneDepth / 2
        let centerY = zoneHeight / 2

        group.addChildNode(labelNode(
            text: centimetres(zoneWidth),
            position: SCNVector3(0, centerY + halfY + margin, -halfZ - margin)
        ))
        group.addChildNode(labelNode(
            text: centimetres(zoneDepth),
            position: SCNVector3(halfX + margin, centerY + halfY + margin, 0)
        ))
        group.addChildNode(labelNode(
            text: centimetres(zoneHeight),
            position: SCNVector3(-halfX - margin, centerY, halfZ + margin)
        ))

        return group
    }

    private func centimetres(_ metres: Float) -> String {
        String(format: "%.0f cm", metres * 100)
    }

    private func labelNode(text: String, position: SCNVector3) -> SCNNode {
        let geometry = SCNText(string: text, extrusionDepth: 0)
        geometry.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        geometry.flatness = 0.1

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.diffuse.contents = UIColor.white
        material.emission.contents = UIColor.white.withAlphaComponent(0.8)
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        // SCNText misura in punti: va riscalato per diventare centimetri reali.
        let scale: Float = 0.0018
        node.scale = SCNVector3(scale, scale, scale)
        // Centra il testo sul proprio punto di ancoraggio.
        let (minBound, maxBound) = geometry.boundingBox
        node.pivot = SCNMatrix4MakeTranslation(
            (minBound.x + maxBound.x) / 2,
            (minBound.y + maxBound.y) / 2,
            0
        )
        node.position = position
        node.renderingOrder = 12

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        node.constraints = [billboard]

        return node
    }

    // MARK: - Vibrazione

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        hapticEngine = try? CHHapticEngine()
        hapticEngine?.isAutoShutdownEnabled = true
        try? hapticEngine?.start()
    }

    /// Vibrazione continua di un secondo all'ingresso nella zona.
    private func playEnterHaptic() {
        guard let engine = hapticEngine else {
            legacyVibrate()
            return
        }
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [intensity, sharpness],
            relativeTime: 0,
            duration: 1
        )
        do {
            try engine.start()
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            // Il player va tenuto vivo per tutta la durata, altrimenti viene
            // deallocato subito e la vibrazione si tronca.
            let player = try engine.makePlayer(with: pattern)
            hapticPlayer = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            legacyVibrate()
        }
    }

    /// Fallback per hardware senza Core Haptics: raffica di vibrazioni di sistema
    /// per coprire circa un secondo.
    private func legacyVibrate() {
        var fired = 0
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            fired += 1
            if fired >= 3 {
                timer.invalidate()
            }
        }
    }

    // MARK: - ARSCNViewDelegate

    public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let sceneView = arView else { return }
        updatePreview(in: sceneView)
    }

    public func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        if let meshAnchor = anchor as? ARMeshAnchor {
            guard showsScanMesh else { return }
            let meshNode = SCNNode(geometry: scanGeometry(from: meshAnchor))
            meshNode.renderingOrder = 1
            node.addChildNode(meshNode)
            meshNodes[meshAnchor.identifier] = meshNode
            return
        }

        if let planeAnchor = anchor as? ARPlaneAnchor,
           planeAnchor.identifier == zonePlaneAnchorID,
           zoneNode == nil {
            let zone = buildZoneNode()
            zone.simdTransform = zoneRelativeTransform
            node.addChildNode(zone)
            zoneNode = zone
            return
        }

        guard anchor.identifier == zoneAnchor?.identifier else { return }
        let zone = buildZoneNode()
        node.addChildNode(zone)
        zoneNode = zone
    }

    public func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        guard showsScanMesh else {
            meshNodes[meshAnchor.identifier]?.removeFromParentNode()
            meshNodes.removeValue(forKey: meshAnchor.identifier)
            return
        }
        // ARKit affina la mesh in continuazione: si sostituisce la geometria del
        // nodo esistente invece di ricrearlo, cosi non si accumulano nodi.
        meshNodes[meshAnchor.identifier]?.geometry = scanGeometry(from: meshAnchor)
    }

    public func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        meshNodes.removeValue(forKey: anchor.identifier)
    }

    // MARK: - ARSessionDelegate

    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        if anchors.contains(where: { ($0 as? ARPlaneAnchor)?.alignment == .horizontal }) {
            horizontalPlaneDetected = true
        }
    }

    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Se la zona e figlia di un piano, la sua posizione nel mondo cambia
        // ogni volta che ARKit raffina quel piano: i calcoli devono seguirla.
        if let planeID = zonePlaneAnchorID,
           let plane = anchors.first(where: { $0.identifier == planeID }) {
            zoneTransform = simd_mul(plane.transform, zoneRelativeTransform)
            return
        }
        guard let identifier = zoneAnchor?.identifier,
              let updated = anchors.first(where: { $0.identifier == identifier }) else { return }
        zoneAnchor = updated
        zoneTransform = updated.transform
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let trackingQuality: String
        switch frame.camera.trackingState {
        case .normal:
            trackingQuality = "normal"
        case .limited:
            trackingQuality = "limited"
        @unknown default:
            trackingQuality = "notAvailable"
        }

        let mappingStatus: String
        switch frame.worldMappingStatus {
        case .mapped:
            mappingStatus = "mapped"
        case .extending:
            mappingStatus = "extending"
        case .limited:
            mappingStatus = "limited"
        case .notAvailable:
            mappingStatus = "notAvailable"
        @unknown default:
            mappingStatus = "notAvailable"
        }

        let trackingPayload: [String: Any] = [
            "trackingQuality": trackingQuality,
            "lidarAvailable": frame.sceneDepth != nil || frame.smoothedSceneDepth != nil,
            "surfaceDetected": horizontalPlaneDetected,
            "mappingStatus": mappingStatus,
            "meshAnchors": frame.anchors.filter { $0 is ARMeshAnchor }.count,
            "previewReady": previewTransform != nil,
        ]
        notifyListeners("trackingStatus", data: trackingPayload)

        guard zoneIsPlaced else { return }

        let localTransform = simd_mul(simd_inverse(zoneTransform), frame.camera.transform)
        let position = SIMD3<Float>(
            localTransform.columns.3.x,
            localTransform.columns.3.y,
            localTransform.columns.3.z
        )

        let phoneHalfWidth: Float = 0.045
        let phoneHalfHeight: Float = 0.08
        let phoneHalfDepth: Float = 0.09
        let xOverlap = intervalOverlap(position.x, half: phoneHalfWidth, lower: -zoneWidth / 2, upper: zoneWidth / 2)
        let yOverlap = intervalOverlap(position.y, half: phoneHalfHeight, lower: 0, upper: zoneHeight)
        let zOverlap = intervalOverlap(position.z, half: phoneHalfDepth, lower: -zoneDepth / 2, upper: zoneDepth / 2)
        // Rapporto sull'overlap massimo ottenibile: con una zona piu piccola del
        // telefono, usare il volume del telefono come riferimento renderebbe lo
        // stato "inside" irraggiungibile. Per zone piu grandi i due coincidono.
        let overlapVolume = xOverlap * yOverlap * zOverlap
        let maxOverlap =
            min(phoneHalfWidth * 2, zoneWidth)
            * min(phoneHalfHeight * 2, zoneHeight)
            * min(phoneHalfDepth * 2, zoneDepth)
        let percent = maxOverlap > 0
            ? min(100, max(0, (overlapVolume / maxOverlap) * 100))
            : 0
        let state: String = percent <= 0 ? "outside" : (percent >= 98 ? "inside" : "partial")

        if state != currentZoneState {
            let previous = currentZoneState
            currentZoneState = state
            if state == "inside", previous != "inside" {
                DispatchQueue.main.async { [weak self] in
                    self?.playEnterHaptic()
                }
            }
        }

        let payload: [String: Any] = [
            "state": state,
            "percent": percent,
            "position": [
                "x": position.x,
                "y": position.y,
                "z": position.z,
            ],
            "trackingQuality": trackingQuality,
            "lidarAvailable": frame.sceneDepth != nil || frame.smoothedSceneDepth != nil,
        ]
        notifyListeners("zoneStatus", data: payload)
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        notifyListeners("zoneError", data: ["message": error.localizedDescription])
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        notifyListeners("zoneError", data: ["message": "La sessione ARKit e stata interrotta."])
    }

    private func intervalOverlap(_ center: Float, half: Float, lower: Float, upper: Float) -> Float {
        max(0, min(center + half, upper) - max(center - half, lower))
    }
}

/// Bridge view controller che registra il plugin nel momento corretto del ciclo
/// di vita: `bridge` non esiste ancora quando il controller viene costruito,
/// esiste solo da `capacitorDidLoad()` in poi.
public class ARZoneBridgeViewController: CAPBridgeViewController {
    override public func capacitorDidLoad() {
        bridge?.registerPluginInstance(ARZoneNative())
    }
}
