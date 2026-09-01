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
                .searchMode: SCNHitTestSearchMode.all.rawValue,
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

        /// Point the camera along the preset direction and dolly it back until the
        /// visible content fits.
        ///
        /// `SCNCameraController.frameNodes` is not used: it reacts unpredictably to the
        /// flat, zero-depth text nodes of the dimension overlay, so the distance is
        /// derived from the content's bounding sphere and the camera's field of view.
        func move(to preset: ViewPreset, animated: Bool) {
            guard let view, let modelScene, let camera = view.pointOfView,
                  let lens = camera.camera else { return }

            let targets = modelScene.framingNodes.filter { !$0.isHidden }
            let nodes = targets.isEmpty ? modelScene.allPartNodes : targets
            let (centre, radius) = boundingSphere(of: nodes)

            let halfAngle = Float(lens.fieldOfView) * .pi / 360
            let distance = max(radius / max(sin(halfAngle), 0.05) * 1.12, 0.5)

            // The target has to be assigned first: setting it re-aims the camera from the
            // controller's own state, which would otherwise overwrite the preset orientation.
            view.defaultCameraController.target = SCNVector3(centre.x, centre.y, centre.z)

            func place() {
                camera.simdPosition = centre + preset.direction * distance
                camera.simdOrientation = simd_quatf(lookAt: -preset.direction, up: preset.up)
            }

            if animated {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.35
                place()
                SCNTransaction.commit()
            } else {
                place()
            }
            view.setNeedsDisplay()
        }

        /// World-space centre and radius of the given nodes, including their own geometry
        /// only — the overlay is passed in already flattened to its leaf nodes.
        private func boundingSphere(of nodes: [SCNNode]) -> (centre: SIMD3<Float>, radius: Float) {
            var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for node in nodes {
                let (localMin, localMax) = node.boundingBox
                let lo = simd_float3(localMin), hi = simd_float3(localMax)
                guard lo.x <= hi.x else { continue }
                for corner in Self.corners(lo, hi) {
                    let world = node.simdConvertPosition(corner, to: nil)
                    minP = simd_min(minP, world)
                    maxP = simd_max(maxP, world)
                }
            }
            guard minP.x <= maxP.x else { return (.zero, 1) }
            return ((minP + maxP) / 2, simd_length(maxP - minP) / 2)
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
