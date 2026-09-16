import ARKit
import AudioToolbox
import Capacitor
import CoreHaptics
import Foundation
import SceneKit
import UIKit

@objc(ARZoneNative)
public class ARZoneNative: CAPPlugin, CAPBridgedPlugin, ARSessionDelegate, ARSCNViewDelegate {
    public let identifier = "ARZoneNative"
    public let jsName = "ARZoneNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isSupported", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "placeZone", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resetSession", returnType: CAPPluginReturnPromise),
    ]

    // Azzurro scuro per il volume, spigoli piu scuri e spessi.
    private let zoneFillColor = UIColor(red: 0.09, green: 0.33, blue: 0.58, alpha: 1)
    private let zoneEdgeColor = UIColor(red: 0.02, green: 0.12, blue: 0.27, alpha: 1)

    private let arSession = ARSession()
    private var arView: ARSCNView?
    private var zoneAnchor: ARAnchor?
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

    override public func load() {
        super.load()
        arSession.delegate = self
        prepareHaptics()
    }

    @objc func isSupported(_ call: CAPPluginCall) {
        let supported = ARWorldTrackingConfiguration.isSupported
        let lidarAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
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

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.isAutoFocusEnabled = true
        let lidarAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if lidarAvailable {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        // La ricostruzione a mesh non serve al rendering, ma da ad ARKit molti
        // piu riferimenti geometrici e riduce la deriva del tracking.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
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

    @objc func placeZone(_ call: CAPPluginCall) {
        guard let frame = arSession.currentFrame else {
            call.reject("ARKit non ha ancora prodotto un frame. Muovi lentamente il telefono.")
            return
        }
        guard let sceneView = arView else {
            call.reject("La vista della fotocamera ARKit non e disponibile.")
            return
        }
        guard frame.camera.trackingState == .normal else {
            call.reject("Tracking ARKit limitato. Muovi lentamente il telefono e riprova.")
            return
        }

        let screenCenter = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        // Prima i piani gia rilevati: agganciarsi a una stima al volo e la causa
        // principale di un ancoraggio che poi scivola quando la mappa si affina.
        var floorTransform: simd_float4x4?
        if let query = sceneView.raycastQuery(
            from: screenCenter,
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        ), let result = arSession.raycast(query).first {
            floorTransform = result.worldTransform
        } else if let query = sceneView.raycastQuery(
            from: screenCenter,
            allowing: .estimatedPlane,
            alignment: .horizontal
        ), let result = arSession.raycast(query).first {
            floorTransform = result.worldTransform
        }

        guard let hit = floorTransform else {
            call.reject("Nessuna superficie orizzontale rilevata. Punta la fotocamera verso il pavimento.")
            return
        }

        let camera = frame.camera.transform
        let forward = SIMD3<Float>(-camera.columns.2.x, 0, -camera.columns.2.z)
        let forwardLength = simd_length(forward)
        guard forwardLength > 0.001 else {
            call.reject("Orientamento della fotocamera non valido.")
            return
        }

        let normalizedForward = forward / forwardLength
        let right = SIMD3<Float>(normalizedForward.z, 0, -normalizedForward.x)
        let floorPosition = SIMD3<Float>(
            hit.columns.3.x,
            hit.columns.3.y,
            hit.columns.3.z
        )

        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(right.x, 0, right.z, 0)
        transform.columns.1 = SIMD4<Float>(0, 1, 0, 0)
        transform.columns.2 = SIMD4<Float>(-normalizedForward.x, 0, -normalizedForward.z, 0)
        transform.columns.3 = SIMD4<Float>(floorPosition.x, floorPosition.y, floorPosition.z, 1)

        clearZone()
        zoneTransform = transform
        zoneIsPlaced = true

        // Il volume vive dentro un ARAnchor: quando ARKit ri-localizza e corregge
        // l'origine del mondo sposta anche l'ancora, quindi il box resta fermo
        // rispetto alla scena reale. Con una matrice fissa sulla rootNode restava
        // invece fermo rispetto a un'origine che nel frattempo si era spostata.
        let anchor = ARAnchor(name: "arZone", transform: transform)
        zoneAnchor = anchor
        arSession.add(anchor: anchor)

        call.resolve(["placed": true])
    }

    @objc func resetSession(_ call: CAPPluginCall) {
        clearZone()
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
        zoneNode?.removeFromParentNode()
        zoneNode = nil
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
        return true
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

    public func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard anchor.identifier == zoneAnchor?.identifier else { return }
        let zone = buildZoneNode()
        node.addChildNode(zone)
        zoneNode = zone
    }

    // MARK: - ARSessionDelegate

    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        if anchors.contains(where: { ($0 as? ARPlaneAnchor)?.alignment == .horizontal }) {
            horizontalPlaneDetected = true
        }
    }

    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Se ARKit corregge l'ancora, i calcoli devono usare la posizione nuova.
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

        let trackingPayload: [String: Any] = [
            "trackingQuality": trackingQuality,
            "lidarAvailable": frame.sceneDepth != nil,
            "surfaceDetected": horizontalPlaneDetected,
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
            "lidarAvailable": frame.sceneDepth != nil,
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
