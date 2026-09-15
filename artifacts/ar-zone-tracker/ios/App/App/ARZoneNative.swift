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
    private var zoneTransform = matrix_identity_float4x4
    private var zoneIsPlaced = false
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
            call.reject("ARWorldTracking is not supported on this iPhone")
            return
        }

        zoneWidth = Float(call.getDouble("width") ?? 20)
        zoneDepth = Float(call.getDouble("depth") ?? 10)
        zoneHeight = Float(call.getDouble("height") ?? 5)

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        let lidarAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if lidarAvailable {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        DispatchQueue.main.async { [weak self] in
            self?.showCameraPreview()
            self?.arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            call.resolve([
                "started": true,
                "lidarAvailable": lidarAvailable,
            ])
        }
    }

    @objc func placeZone(_ call: CAPPluginCall) {
        guard let frame = arSession.currentFrame else {
            call.reject("AR session has not produced a frame yet")
            return
        }

        let camera = frame.camera.transform
        let forward = SIMD3<Float>(-camera.columns.2.x, 0, -camera.columns.2.z)
        let normalizedForward = simd_normalize(forward)
        let right = SIMD3<Float>(normalizedForward.z, 0, -normalizedForward.x)
        let cameraPosition = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let placement = cameraPosition + normalizedForward * 2.0

        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(right.x, 0, right.z, 0)
        transform.columns.1 = SIMD4<Float>(0, 1, 0, 0)
        transform.columns.2 = SIMD4<Float>(-normalizedForward.x, 0, -normalizedForward.z, 0)
        transform.columns.3 = SIMD4<Float>(placement.x, cameraPosition.y - 1.2, placement.z, 1)
        zoneTransform = transform
        zoneIsPlaced = true

        call.resolve(["placed": true])
    }

    @objc func resetSession(_ call: CAPPluginCall) {
        zoneIsPlaced = false
        arSession.pause()
        arView?.removeFromSuperview()
        arView = nil
        bridge?.webView?.isOpaque = true
        call.resolve()
    }

    private func showCameraPreview() {
        guard arView == nil, let viewController = bridge?.viewController else { return }

        let sceneView = ARSCNView(frame: viewController.view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.session = arSession
        sceneView.scene = SCNScene()
        sceneView.backgroundColor = .black
        viewController.view.insertSubview(sceneView, at: 0)
        bridge?.webView?.isOpaque = false
        bridge?.webView?.backgroundColor = .clear
        arView = sceneView
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
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

        let status: String
        switch frame.camera.trackingState {
        case .normal:
            status = "normal"
        case .limited:
            status = "limited"
        @unknown default:
            status = "notAvailable"
        }

        let payload: [String: Any] = [
            "state": state,
            "percent": percent,
            "position": [
                "x": position.x,
                "y": position.y,
                "z": position.z,
            ],
            "trackingQuality": status,
            "lidarAvailable": frame.sceneDepth != nil,
        ]

        DispatchQueue.main.async { [weak self] in
            self?.notifyListeners("zoneStatus", data: payload)
        }
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        notifyListeners("zoneError", data: ["message": error.localizedDescription])
    }

    private func intervalOverlap(_ center: Float, half: Float, lower: Float, upper: Float) -> Float {
        max(0, min(center + half, upper) - max(center - half, lower))
    }
}