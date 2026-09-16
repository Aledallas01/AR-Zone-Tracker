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

    private func renderZoneVolume() {
        guard let scene = arView?.scene else { return }

        zoneNode?.removeFromParentNode()

        let container = SCNNode()
        container.simdTransform = zoneTransform

        let volume = SCNBox(
            width: CGFloat(zoneWidth),
            height: CGFloat(zoneHeight),
            length: CGFloat(zoneDepth),
            chamferRadius: 0
        )
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.18)
        material.emission.contents = UIColor.systemGreen.withAlphaComponent(0.12)
        material.isDoubleSided = true
        material.fillMode = .lines
        volume.materials = [material]

        let volumeNode = SCNNode(geometry: volume)
        volumeNode.position = SCNVector3(0, zoneHeight / 2, 0)
        container.addChildNode(volumeNode)
        scene.rootNode.addChildNode(container)
        zoneNode = container
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