import SwiftUI
import SceneKit
import simd

/// SwiftUI wrapper around `SCNView`.
///
/// SceneKit's built-in camera controller supplies the orbit / pinch / two-finger-pan
/// gestures; a single-tap recogniser on top of it performs part picking.
struct ModelSceneView: UIViewRepresentable {

    let modelScene: ModelScene
    var display: DisplayState
    /// Bumped by the owner to request a camera move; the preset itself may repeat.
    var frameRequest: Int
    var preset: ViewPreset
    var onPick: (Int?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = modelScene.scene
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = .clear

        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 500
        camera.fieldOfView = 38
        camera.wantsHDR = false
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.simdPosition = SIMD3(4, 3, -6)
        modelScene.scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        context.coordinator.view = view
        context.coordinator.modelScene = modelScene
        modelScene.apply(display)
        DispatchQueue.main.async { context.coordinator.move(to: preset, animated: false) }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onPick = onPick
        modelScene.apply(display)

        if context.coordinator.lastFrameRequest != frameRequest {
            context.coordinator.lastFrameRequest = frameRequest
            context.coordinator.move(to: preset, animated: true)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPick: (Int?) -> Void
        weak var view: SCNView?
        var modelScene: ModelScene?
        var lastFrameRequest = 0

        init(onPick: @escaping (Int?) -> Void) {
            self.onPick = onPick
        }

        @objc func handleTap(_ recogniser: UITapGestureRecognizer) {
            guard let view, let modelScene else { return }
            let point = recogniser.location(in: view)
            let options: [SCNHitTestOption: Any] = [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: true,
                .boundingBoxOnly: false
            ]
            let hits = view.hitTest(point, options: options)
            for hit in hits {
                if let id = modelScene.partID(for: hit) {
                    onPick(id)
                    return
                }
            }
            onPick(nil)
        }

        /// Point the camera along the preset direction, then dolly until the visible
        /// parts fill the viewport.
        func move(to preset: ViewPreset, animated: Bool) {
            guard let view, let modelScene, let camera = view.pointOfView else { return }

            let targets = modelScene.allPartNodes.filter { !$0.isHidden }
            let nodes = targets.isEmpty ? modelScene.allPartNodes : targets

            let radius = max(boundingRadius(of: nodes), 0.5)
            camera.simdPosition = preset.direction * radius * 3.2
            camera.simdOrientation = simd_quatf(lookAt: -preset.direction, up: preset.up)

            let controller = view.defaultCameraController
            controller.target = SCNVector3Zero

            func fit() {
                controller.frameNodes(nodes)
                // frameNodes fits tight to the bounds; back off so the model does not
                // touch the viewport edges or slide under the sidebar.
                let target = simd_float3(controller.target)
                camera.simdPosition = target + (camera.simdPosition - target) * 1.22
            }

            if animated {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.35
                fit()
                SCNTransaction.commit()
            } else {
                fit()
            }
            view.setNeedsDisplay()
        }

        private func boundingRadius(of nodes: [SCNNode]) -> Float {
            var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for node in nodes {
                let (localMin, localMax) = node.boundingBox
                for corner in Self.corners(simd_float3(localMin), simd_float3(localMax)) {
                    let world = node.simdConvertPosition(corner, to: nil)
                    minP = simd_min(minP, world)
                    maxP = simd_max(maxP, world)
                }
            }
            guard minP.x <= maxP.x else { return 1 }
            return simd_length(maxP - minP) / 2
        }

        private static func corners(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> [SIMD3<Float>] {
            [SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(lo.x, hi.y, lo.z),
             SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z),
             SIMD3(lo.x, hi.y, hi.z), SIMD3(hi.x, hi.y, hi.z)]
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

extension simd_quatf {
    /// Orientation for a camera whose local front is -Z.
    init(lookAt forward: SIMD3<Float>, up: SIMD3<Float>) {
        let f = simd_normalize(forward)
        var upVector = up
        if abs(simd_dot(f, simd_normalize(upVector))) > 0.999 {
            upVector = SIMD3(0, 0, 1)
        }
        let right = simd_normalize(simd_cross(upVector, -f))
        let trueUp = simd_cross(-f, right)
        self.init(simd_float3x3(right, trueUp, -f))
    }
}
