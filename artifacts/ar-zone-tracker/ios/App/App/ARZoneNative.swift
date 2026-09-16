import ARKit
import Capacitor
import Foundation
import SceneKit
import UIKit

@objc(ARZoneNative)
public class ARZoneNative: CAPPlugin, CAPBridgedPlugin, ARSessionDelegate {
    public let identifier = "ARZoneNative"
    public let jsName = "ARZoneNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isSupported", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "placeZone", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resetSession", returnType: CAPPluginReturnPromise),
    ]

    private let arSession = ARSession()
    private var arView: ARSCNView?
    private var zoneNode: SCNNode?
    private var zoneFillMaterial: SCNMaterial?
    private var zoneEdgeMaterial: SCNMaterial?
    private var zoneFloorMaterial: SCNMaterial?
    private var currentZoneState = ""
    private var zoneTransform = matrix_identity_float4x4
    private var zoneIsPlaced = false
    private var horizontalPlaneDetected = false
    private var zoneWidth: Float = 20
    private var zoneDepth: Float = 10
    private var zoneHeight: Float = 5

    override public func load() {
        super.load()
        arSession.delegate = self
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
            call.reject("ARWorldTracking non è supportato su questo iPhone.")
            return
        }

        zoneWidth = max(0.1, Float(call.getDouble("width") ?? 20))
        zoneDepth = max(0.1, Float(call.getDouble("depth") ?? 10))
        zoneHeight = max(0.1, Float(call.getDouble("height") ?? 5))
        zoneIsPlaced = false
        horizontalPlaneDetected = false
        zoneNode?.removeFromParentNode()
        zoneNode = nil

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        let lidarAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if lidarAvailable {
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

    @objc func placeZone(_ call: CAPPluginCall) {
        guard let frame = arSession.currentFrame else {
            call.reject("ARKit non ha ancora prodotto un frame. Muovi lentamente il telefono.")
            return
        }
        guard let sceneView = arView else {
            call.reject("La vista della fotocamera ARKit non è disponibile.")
            return
        }
        guard frame.camera.trackingState == .normal else {
            call.reject("Tracking ARKit limitato. Muovi lentamente il telefono e riprova.")
            return
        }

        let screenCenter = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        let hitTypes: ARHitTestResult.ResultType = [
            .existingPlaneUsingExtent,
            .estimatedHorizontalPlane,
        ]
        guard let hit = sceneView.hitTest(screenCenter, types: hitTypes).first else {
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
            hit.worldTransform.columns.3.x,
            hit.worldTransform.columns.3.y,
            hit.worldTransform.columns.3.z
        )

        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(right.x, 0, right.z, 0)
        transform.columns.1 = SIMD4<Float>(0, 1, 0, 0)
        transform.columns.2 = SIMD4<Float>(-normalizedForward.x, 0, -normalizedForward.z, 0)
        transform.columns.3 = SIMD4<Float>(floorPosition.x, floorPosition.y, floorPosition.z, 1)
        zoneTransform = transform
        zoneIsPlaced = true
        renderZoneVolume()

        call.resolve(["placed": true])
    }

    @objc func resetSession(_ call: CAPPluginCall) {
        zoneIsPlaced = false
        horizontalPlaneDetected = false
        zoneNode?.removeFromParentNode()
        zoneNode = nil
        zoneFillMaterial = nil
        zoneEdgeMaterial = nil
        zoneFloorMaterial = nil
        currentZoneState = ""
        arSession.pause()
        arView?.removeFromSuperview()
        arView = nil
        bridge?.webView?.isOpaque = true
        bridge?.webView?.backgroundColor = nil
        call.resolve()
    }

    private func showCameraPreview() -> Bool {
        guard arView == nil, let viewController = bridge?.viewController else { return false }

        let sceneView = ARSCNView(frame: viewController.view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.session = arSession
        sceneView.scene = SCNScene()
        sceneView.backgroundColor = .clear
        sceneView.rendersCameraGrain = true
        viewController.view.insertSubview(sceneView, at: 0)
        viewController.view.backgroundColor = .clear
        bridge?.webView?.isOpaque = false
        bridge?.webView?.backgroundColor = .clear
        bridge?.webView?.scrollView.backgroundColor = .clear
        arView = sceneView
        return true
    }

    /// Colori per stato: verde = dentro, ambra = parzialmente dentro,
    /// arancio = fuori. Servono a capire a colpo d'occhio dove sei.
    private func zoneColor(for state: String) -> UIColor {
        switch state {
        case "inside":
            return UIColor(red: 0.24, green: 0.84, blue: 0.53, alpha: 1)
        case "partial":
            return UIColor(red: 0.94, green: 0.71, blue: 0.31, alpha: 1)
        default:
            return UIColor(red: 0.93, green: 0.55, blue: 0.33, alpha: 1)
        }
    }

    private func applyZoneAppearance(for state: String) {
        let color = zoneColor(for: state)
        zoneFillMaterial?.diffuse.contents = color.withAlphaComponent(0.20)
        zoneFillMaterial?.emission.contents = color.withAlphaComponent(0.16)
        zoneEdgeMaterial?.diffuse.contents = color.withAlphaComponent(0.95)
        zoneEdgeMaterial?.emission.contents = color.withAlphaComponent(0.85)
        zoneFloorMaterial?.diffuse.contents = color.withAlphaComponent(0.32)
        zoneFloorMaterial?.emission.contents = color.withAlphaComponent(0.22)
    }

    private func renderZoneVolume() {
        guard let scene = arView?.scene else { return }

        zoneNode?.removeFromParentNode()

        let container = SCNNode()
        container.simdTransform = zoneTransform

        let width = CGFloat(zoneWidth)
        let height = CGFloat(zoneHeight)
        let depth = CGFloat(zoneDepth)
        let centerY = zoneHeight / 2

        // Volume pieno traslucido. writesToDepthBuffer = false evita che le
        // facce del box si occludano tra loro e nascondano il contenuto.
        let fillMaterial = SCNMaterial()
        fillMaterial.lightingModel = .constant
        fillMaterial.isDoubleSided = true
        fillMaterial.writesToDepthBuffer = false
        fillMaterial.blendMode = .alpha
        let fillBox = SCNBox(width: width, height: height, length: depth, chamferRadius: 0)
        fillBox.materials = [fillMaterial]
        let fillNode = SCNNode(geometry: fillBox)
        fillNode.position = SCNVector3(0, centerY, 0)
        fillNode.renderingOrder = 10

        // Spigoli pieni: danno la forma anche guardando il volume da dentro.
        let edgeMaterial = SCNMaterial()
        edgeMaterial.lightingModel = .constant
        edgeMaterial.isDoubleSided = true
        edgeMaterial.writesToDepthBuffer = false
        edgeMaterial.fillMode = .lines
        let edgeBox = SCNBox(width: width, height: height, length: depth, chamferRadius: 0)
        edgeBox.materials = [edgeMaterial]
        let edgeNode = SCNNode(geometry: edgeBox)
        edgeNode.position = SCNVector3(0, centerY, 0)
        edgeNode.renderingOrder = 11

        // Impronta a terra: ancora visivamente il volume al pavimento.
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .constant
        floorMaterial.isDoubleSided = true
        floorMaterial.writesToDepthBuffer = false
        let floorPlane = SCNPlane(width: width, height: depth)
        floorPlane.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floorPlane)
        floorNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        floorNode.position = SCNVector3(0, 0.02, 0)
        floorNode.renderingOrder = 9

        container.addChildNode(floorNode)
        container.addChildNode(fillNode)
        container.addChildNode(edgeNode)
        scene.rootNode.addChildNode(container)

        zoneFillMaterial = fillMaterial
        zoneEdgeMaterial = edgeMaterial
        zoneFloorMaterial = floorMaterial
        zoneNode = container
        currentZoneState = ""
        applyZoneAppearance(for: "outside")
    }

    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        if anchors.contains(where: { ($0 as? ARPlaneAnchor)?.alignment == .horizontal }) {
            horizontalPlaneDetected = true
        }
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
        let phoneVolume = (phoneHalfWidth * 2) * (phoneHalfHeight * 2) * (phoneHalfDepth * 2)
        let overlapVolume = xOverlap * yOverlap * zOverlap
        let percent = min(100, max(0, (overlapVolume / phoneVolume) * 100))
        let state: String = percent <= 0 ? "outside" : (percent >= 98 ? "inside" : "partial")

        if state != currentZoneState {
            currentZoneState = state
            DispatchQueue.main.async { [weak self] in
                self?.applyZoneAppearance(for: state)
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
        notifyListeners("zoneError", data: ["message": "La sessione ARKit è stata interrotta."])
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
