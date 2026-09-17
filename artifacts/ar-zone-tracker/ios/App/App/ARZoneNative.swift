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
        CAPPluginMethod(name: "previewZone", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "placeZone", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeZone", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resetSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getConfig", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setConfig", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "runShortcut", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearSavedZones", returnType: CAPPluginReturnPromise),
    ]

    /// Una zona posizionata: geometria, ancora e stato di ingresso.
    private struct Zone {
        let id: String
        var color: UIColor
        var size: SIMD3<Float>
        var anchor: ARAnchor?
        var node: SCNNode?
        var transform: simd_float4x4
        var state = "outside"
        var reportedPercent: Float = -1
    }

    /// Prefisso del nome delle ancore: e la chiave con cui le zone si ritrovano
    /// dentro una ARWorldMap ricaricata.
    private let anchorPrefix = "arZone:"
    /// Metadati delle zone (colore e misure) accanto alla mappa: la ARWorldMap
    /// conserva le ancore, non cosa devono disegnare.
    private let zoneMetaKey = "arzone.zoneMeta"
    /// Configurazione lato interfaccia (nomi, comandi rapidi), salvata qui e non
    /// in localStorage, che iOS puo svuotare sotto pressione di memoria.
    private let configKey = "arzone.config"

    private let scanMeshColor = UIColor(red: 0.42, green: 0.78, blue: 1, alpha: 1)
    private let defaultZoneColor = UIColor(red: 0.09, green: 0.33, blue: 0.58, alpha: 1)

    private let arSession = ARSession()
    private var arView: ARSCNView?
    private var zones: [String: Zone] = [:]
    private var horizontalPlaneDetected = false
    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticPatternPlayer?

    /// Nodi della mesh LiDAR, uno per ARMeshAnchor. Mostrati solo mentre si
    /// scansiona: servono a far vedere che la ricostruzione sta avvenendo.
    private var meshNodes: [UUID: SCNNode] = [:]
    private var showsScanMesh = true

    /// Anteprima del volume da aggiungere: segue il centro dello schermo, cosi
    /// si vede esattamente dove finira il box prima di confermarlo.
    private var previewNode: SCNNode?
    private var previewTransform: simd_float4x4?
    private var previewColor: UIColor
    private var previewSize = SIMD3<Float>(0.2, 0.05, 0.1)
    private var showsPreview = false

    /// Quote sui lati, accese e spente con un doppio tap su un box.
    private var dimensionsVisible = false

    private var isRelocalizing = false
    private var hasSavedZones = false

    override public init() {
        previewColor = UIColor(red: 0.09, green: 0.33, blue: 0.58, alpha: 1)
        super.init()
    }

    override public func load() {
        super.load()
        arSession.delegate = self
        prepareHaptics()
        // Il momento migliore per salvare e quando l'app esce di scena: la mappa
        // e al massimo della completezza raggiunta in quella sessione.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func handleEnterBackground() {
        guard !zones.isEmpty else { return }
        saveWorld()
    }

    // MARK: - Sessione

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

        removeAllZoneNodes()
        zones.removeAll()
        showsScanMesh = true
        showsPreview = false

        let configuration = ARWorldTrackingConfiguration()
        // Anche i piani verticali: piu ancore stabili in scena significa meno
        // deriva, non servono solo a poggiarci sopra le zone.
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isAutoFocusEnabled = true

        let lidarAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        if lidarAvailable {
            // ARKit ricostruisce una mesh dell'ambiente e si localizza sulla
            // geometria, non sui soli punti caratteristici della camera.
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        let savedMap = loadWorldMap()
        if let savedMap {
            configuration.initialWorldMap = savedMap
            isRelocalizing = true
            hasSavedZones = true
        } else {
            isRelocalizing = false
            hasSavedZones = false
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
                "restoringSavedZones": savedMap != nil,
            ])
        }
    }

    @objc func resetSession(_ call: CAPPluginCall) {
        removeAllZoneNodes()
        zones.removeAll()
        showsPreview = false
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

    // MARK: - Anteprima e posizionamento

    /// Entra in modalita aggiunta: il box semitrasparente segue il centro dello
    /// schermo. Non tocca le zone gia posizionate.
    @objc func previewZone(_ call: CAPPluginCall) {
        previewColor = color(fromHex: call.getString("color")) ?? defaultZoneColor
        previewSize = SIMD3<Float>(
            max(0.01, Float(call.getDouble("width") ?? 0.2)),
            max(0.01, Float(call.getDouble("height") ?? 0.05)),
            max(0.01, Float(call.getDouble("depth") ?? 0.1))
        )
        showsPreview = true
        showsScanMesh = true
        hidePreview()
        call.resolve(["preview": true])
    }

    @objc func cancelPreview(_ call: CAPPluginCall) {
        showsPreview = false
        hidePreview()
        call.resolve(["preview": false])
    }

    /// Conferma la posizione mostrata dall'anteprima. Si usa la trasformazione
    /// gia a schermo, non una nuova: cosi il box finisce esattamente dove lo si
    /// stava vedendo.
    @objc func placeZone(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), !id.isEmpty else {
            call.reject("Identificativo della zona mancante.")
            return
        }
        guard let transform = previewTransform else {
            call.reject("Nessuna superficie inquadrata. Punta il centro dello schermo verso il pavimento.")
            return
        }

        removeZone(id: id)

        let zoneColor = color(fromHex: call.getString("color")) ?? previewColor
        let size = previewSize
        let anchor = ARAnchor(name: anchorPrefix + id, transform: transform)
        zones[id] = Zone(
            id: id,
            color: zoneColor,
            size: size,
            anchor: anchor,
            node: nil,
            transform: transform
        )
        arSession.add(anchor: anchor)
        storeZoneMeta()

        showsPreview = false
        showsScanMesh = false
        removeScanMesh()
        hidePreview()
        saveWorld()

        call.resolve(["placed": true, "id": id])
    }

    @objc func removeZone(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), !id.isEmpty else {
            call.reject("Identificativo della zona mancante.")
            return
        }
        removeZone(id: id)
        storeZoneMeta()
        saveWorld()
        call.resolve(["removed": true, "id": id])
    }

    private func removeZone(id: String) {
        guard let zone = zones.removeValue(forKey: id) else { return }
        if let anchor = zone.anchor {
            arSession.remove(anchor: anchor)
        }
        let node = zone.node
        DispatchQueue.main.async {
            node?.removeFromParentNode()
        }
    }

    private func removeAllZoneNodes() {
        let nodes = zones.values.compactMap(\.node)
        for zone in zones.values {
            if let anchor = zone.anchor {
                arSession.remove(anchor: anchor)
            }
        }
        DispatchQueue.main.async {
            nodes.forEach { $0.removeFromParentNode() }
        }
    }

    // MARK: - Configurazione e persistenza

    @objc func getConfig(_ call: CAPPluginCall) {
        let json = UserDefaults.standard.string(forKey: configKey) ?? ""
        DispatchQueue.main.async {
            let available = URL(string: "shortcuts://").map {
                UIApplication.shared.canOpenURL($0)
            } ?? false
            call.resolve([
                "config": json,
                "shortcutsAvailable": available,
            ])
        }
    }

    @objc func setConfig(_ call: CAPPluginCall) {
        let json = call.getString("config") ?? ""
        if json.isEmpty {
            UserDefaults.standard.removeObject(forKey: configKey)
        } else {
            UserDefaults.standard.set(json, forKey: configKey)
        }
        call.resolve(["saved": true])
    }

    @objc func clearSavedZones(_ call: CAPPluginCall) {
        try? FileManager.default.removeItem(at: worldMapURL)
        UserDefaults.standard.removeObject(forKey: zoneMetaKey)
        removeAllZoneNodes()
        zones.removeAll()
        isRelocalizing = false
        hasSavedZones = false
        call.resolve(["cleared": true])
    }

    private var worldMapURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("arzone-worldmap.arexperience")
    }

    private func loadWorldMap() -> ARWorldMap? {
        guard let data = try? Data(contentsOf: worldMapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    /// La mappa include le ancore della sessione, quindi salvandola si salvano
    /// anche le zone: al ricaricamento ARKit le ripropone da sola.
    private func saveWorld() {
        arSession.getCurrentWorldMap { [weak self] map, _ in
            guard let self, let map else { return }
            guard let data = try? NSKeyedArchiver.archivedData(
                withRootObject: map,
                requiringSecureCoding: true
            ) else { return }
            try? data.write(to: self.worldMapURL, options: [.atomic])
            self.hasSavedZones = true
        }
    }

    /// Colore e misure per id: la ARWorldMap sa dove sta un'ancora, non di che
    /// colore e quanto deve essere grande il box da disegnarci sopra.
    private func storeZoneMeta() {
        var meta: [String: [String: Any]] = [:]
        for (id, zone) in zones {
            meta[id] = [
                "color": hex(from: zone.color),
                "width": Double(zone.size.x),
                "height": Double(zone.size.y),
                "depth": Double(zone.size.z),
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: meta) else { return }
        UserDefaults.standard.set(data, forKey: zoneMetaKey)
    }

    private func loadZoneMeta(for id: String) -> (UIColor, SIMD3<Float>) {
        guard let data = UserDefaults.standard.data(forKey: zoneMetaKey),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              let entry = meta[id] else {
            return (defaultZoneColor, SIMD3<Float>(0.2, 0.05, 0.1))
        }
        let zoneColor = color(fromHex: entry["color"] as? String) ?? defaultZoneColor
        let size = SIMD3<Float>(
            Float(entry["width"] as? Double ?? 0.2),
            Float(entry["height"] as? Double ?? 0.05),
            Float(entry["depth"] as? Double ?? 0.1)
        )
        return (zoneColor, size)
    }

    // MARK: - Comandi rapidi

    /// Apre Comandi Rapidi ed esegue lo shortcut. Si usa x-callback-url con
    /// x-success: senza, alla fine si resterebbe dentro l'app Comandi Rapidi.
    @objc func runShortcut(_ call: CAPPluginCall) {
        let name = (call.getString("name") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            call.reject("Nessun comando rapido indicato.")
            return
        }

        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "x-success", value: "arzonetracker://"),
            URLQueryItem(name: "x-error", value: "arzonetracker://"),
        ]
        guard let url = components?.url else {
            call.reject("Nome del comando rapido non valido.")
            return
        }

        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { opened in
                if opened {
                    call.resolve(["launched": true, "name": name])
                } else {
                    call.reject("Impossibile aprire Comandi Rapidi.")
                }
            }
        }
    }

    // MARK: - Vista e gesti

    private func showCameraPreview() -> Bool {
        guard arView == nil, let viewController = bridge?.viewController else { return true }

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
        // alla scena: il riconoscitore va messo sulla webview, senza rubarle gli
        // eventi, e il test 3D si fa convertendo le coordinate.
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
        guard let sceneView = arView, !zones.isEmpty else { return }
        let point = gesture.location(in: sceneView)
        let hits = sceneView.hitTest(point, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
        ])
        let zoneNodes = zones.values.compactMap(\.node)
        let touchedZone = hits.contains { hit in
            var node: SCNNode? = hit.node
            while let current = node {
                if zoneNodes.contains(where: { $0 === current }) { return true }
                node = current.parent
            }
            return false
        }
        guard touchedZone else { return }

        dimensionsVisible.toggle()
        for zone in zones.values {
            zone.node?
                .childNode(withName: "dimensions", recursively: false)?
                .isHidden = !dimensionsVisible
        }
    }

    /// Trasformazione del box a partire dal centro dello schermo: raycast sulla
    /// geometria gia rilevata e orientamento preso dalla direzione della camera.
    private func placementTarget(in sceneView: ARSCNView, frame: ARFrame) -> simd_float4x4? {
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
        return transform
    }

    private func updatePreview(in sceneView: ARSCNView) {
        guard showsPreview else {
            if previewNode != nil { hidePreview() }
            return
        }
        guard let frame = arSession.currentFrame,
              frame.camera.trackingState == .normal,
              let transform = placementTarget(in: sceneView, frame: frame) else {
            previewTransform = nil
            previewNode?.isHidden = true
            return
        }

        previewTransform = transform

        let node: SCNNode
        if let existing = previewNode {
            node = existing
        } else {
            node = buildZoneNode(color: previewColor, size: previewSize)
            node.opacity = 0.55
            sceneView.scene.rootNode.addChildNode(node)
            previewNode = node
        }
        node.isHidden = false
        node.simdTransform = transform
    }

    private func hidePreview() {
        previewTransform = nil
        let node = previewNode
        previewNode = nil
        DispatchQueue.main.async {
            node?.removeFromParentNode()
        }
    }

    // MARK: - Mesh della scansione

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
        let faceData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
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

    // MARK: - Geometria del volume

    private func buildZoneNode(color zoneColor: UIColor, size: SIMD3<Float>) -> SCNNode {
        let container = SCNNode()
        let zoneWidth = size.x
        let zoneHeight = size.y
        let zoneDepth = size.z
        let centerY = zoneHeight / 2
        let edgeColor = darkened(zoneColor)

        let fillMaterial = SCNMaterial()
        fillMaterial.lightingModel = .constant
        fillMaterial.isDoubleSided = true
        fillMaterial.writesToDepthBuffer = false
        fillMaterial.diffuse.contents = zoneColor.withAlphaComponent(0.30)
        fillMaterial.emission.contents = zoneColor.withAlphaComponent(0.16)
        let fillBox = SCNBox(
            width: CGFloat(zoneWidth),
            height: CGFloat(zoneHeight),
            length: CGFloat(zoneDepth),
            chamferRadius: 0
        )
        fillBox.materials = [fillMaterial]
        let fillNode = SCNNode(geometry: fillBox)
        fillNode.position = SCNVector3(0, centerY, 0)
        fillNode.renderingOrder = 10
        container.addChildNode(fillNode)

        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .constant
        floorMaterial.isDoubleSided = true
        floorMaterial.writesToDepthBuffer = false
        floorMaterial.diffuse.contents = edgeColor.withAlphaComponent(0.35)
        let floorPlane = SCNPlane(width: CGFloat(zoneWidth), height: CGFloat(zoneDepth))
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
        edgeMaterial.diffuse.contents = edgeColor
        edgeMaterial.emission.contents = edgeColor.withAlphaComponent(0.55)

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

        let dimensions = buildDimensionLabels(size: size, thickness: thickness)
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

    private func buildDimensionLabels(size: SIMD3<Float>, thickness: Float) -> SCNNode {
        let group = SCNNode()
        let margin = thickness * 3
        let halfX = size.x / 2
        let halfY = size.y / 2
        let halfZ = size.z / 2
        let centerY = size.y / 2

        group.addChildNode(labelNode(
            text: centimetres(size.x),
            position: SCNVector3(0, centerY + halfY + margin, -halfZ - margin)
        ))
        group.addChildNode(labelNode(
            text: centimetres(size.z),
            position: SCNVector3(halfX + margin, centerY + halfY + margin, 0)
        ))
        group.addChildNode(labelNode(
            text: centimetres(size.y),
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

    // MARK: - Colori

    private func color(fromHex hex: String?) -> UIColor? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    private func hex(from color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    /// Spigoli piu scuri del riempimento, qualunque sia il colore della zona.
    private func darkened(_ color: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor(red: red * 0.42, green: green * 0.42, blue: blue * 0.42, alpha: 1)
    }

    // MARK: - Vibrazione

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        hapticEngine = try? CHHapticEngine()
        hapticEngine?.isAutoShutdownEnabled = true
        try? hapticEngine?.start()
    }

    /// Vibrazione continua di un secondo all'ingresso in una zona.
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

        guard let name = anchor.name, name.hasPrefix(anchorPrefix) else { return }
        let id = String(name.dropFirst(anchorPrefix.count))
        // Colore e misure non stanno nella ARWorldMap: per un'ancora
        // ripristinata vanno ripresi dai metadati salvati a parte.
        let zoneColor = zones[id]?.color ?? loadZoneMeta(for: id).0
        let size = zones[id]?.size ?? loadZoneMeta(for: id).1
        guard zones[id]?.node == nil else { return }

        let zoneNode = buildZoneNode(color: zoneColor, size: size)
        node.addChildNode(zoneNode)

        if zones[id] != nil {
            zones[id]?.node = zoneNode
        } else {
            zones[id] = Zone(
                id: id,
                color: zoneColor,
                size: size,
                anchor: anchor,
                node: zoneNode,
                transform: anchor.transform
            )
        }
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

        // Ancore di zona che riemergono da una mappa salvata.
        for anchor in anchors {
            guard let name = anchor.name, name.hasPrefix(anchorPrefix) else { continue }
            let id = String(name.dropFirst(anchorPrefix.count))
            if zones[id] == nil {
                let meta = loadZoneMeta(for: id)
                zones[id] = Zone(
                    id: id,
                    color: meta.0,
                    size: meta.1,
                    anchor: anchor,
                    node: nil,
                    transform: anchor.transform
                )
            } else {
                zones[id]?.anchor = anchor
                zones[id]?.transform = anchor.transform
            }
            showsScanMesh = false
        }
    }

    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let name = anchor.name, name.hasPrefix(anchorPrefix) else { continue }
            let id = String(name.dropFirst(anchorPrefix.count))
            zones[id]?.anchor = anchor
            zones[id]?.transform = anchor.transform
        }
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let trackingQuality: String
        switch frame.camera.trackingState {
        case .normal:
            trackingQuality = "normal"
            isRelocalizing = false
        case .limited(let reason):
            trackingQuality = "limited"
            // Relocalizing significa che ARKit sta cercando di riconoscere
            // l'ambiente della mappa salvata: attesa normale, non un errore.
            if case .relocalizing = reason {
                isRelocalizing = true
            } else {
                isRelocalizing = false
            }
        @unknown default:
            trackingQuality = "notAvailable"
        }

        let mappingStatus: String
        switch frame.worldMappingStatus {
        case .mapped: mappingStatus = "mapped"
        case .extending: mappingStatus = "extending"
        case .limited: mappingStatus = "limited"
        case .notAvailable: mappingStatus = "notAvailable"
        @unknown default: mappingStatus = "notAvailable"
        }

        notifyListeners("trackingStatus", data: [
            "trackingQuality": trackingQuality,
            "lidarAvailable": frame.sceneDepth != nil || frame.smoothedSceneDepth != nil,
            "surfaceDetected": horizontalPlaneDetected,
            "mappingStatus": mappingStatus,
            "meshAnchors": frame.anchors.filter { $0 is ARMeshAnchor }.count,
            "previewReady": previewTransform != nil,
            "relocalizing": isRelocalizing,
            "zoneCount": zones.count,
            "hasSavedZones": hasSavedZones,
        ])

        guard !zones.isEmpty else { return }
        evaluateZones(camera: frame.camera.transform)
    }

    /// Stato di ogni zona rispetto al telefono. Gli eventi partono solo sui
    /// cambiamenti: un invio per frame per zona saturerebbe il ponte con JS.
    private func evaluateZones(camera: simd_float4x4) {
        let phoneHalf = SIMD3<Float>(0.045, 0.08, 0.09)

        for (id, zone) in zones {
            let localTransform = simd_mul(simd_inverse(zone.transform), camera)
            let position = SIMD3<Float>(
                localTransform.columns.3.x,
                localTransform.columns.3.y,
                localTransform.columns.3.z
            )

            let xOverlap = intervalOverlap(
                position.x, half: phoneHalf.x, lower: -zone.size.x / 2, upper: zone.size.x / 2
            )
            let yOverlap = intervalOverlap(
                position.y, half: phoneHalf.y, lower: 0, upper: zone.size.y
            )
            let zOverlap = intervalOverlap(
                position.z, half: phoneHalf.z, lower: -zone.size.z / 2, upper: zone.size.z / 2
            )
            // Rapporto sull'overlap massimo ottenibile: con una zona piu piccola
            // del telefono, usare il volume del telefono come riferimento
            // renderebbe lo stato "inside" irraggiungibile.
            let overlapVolume = xOverlap * yOverlap * zOverlap
            let maxOverlap =
                min(phoneHalf.x * 2, zone.size.x)
                * min(phoneHalf.y * 2, zone.size.y)
                * min(phoneHalf.z * 2, zone.size.z)
            let percent = maxOverlap > 0
                ? min(100, max(0, (overlapVolume / maxOverlap) * 100))
                : 0
            let state: String = percent <= 0 ? "outside" : (percent >= 98 ? "inside" : "partial")

            let previousState = zone.state
            if state != previousState {
                zones[id]?.state = state
                if state == "inside" {
                    DispatchQueue.main.async { [weak self] in
                        self?.playEnterHaptic()
                    }
                    notifyListeners("zoneEnter", data: ["id": id])
                } else if previousState == "inside" {
                    notifyListeners("zoneExit", data: ["id": id])
                }
            }

            if abs(percent - zone.reportedPercent) >= 1 || state != previousState {
                zones[id]?.reportedPercent = percent
                notifyListeners("zoneStatus", data: [
                    "id": id,
                    "state": state,
                    "percent": percent,
                ])
            }
        }
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
