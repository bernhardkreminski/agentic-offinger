import Foundation
import SceneKit
import SwiftUI
import simd

/// How the model should currently be drawn.
struct DisplayState: Equatable {
    var visibleLayers: Set<String> = []
    var selectedPartID: Int?
    var showEdges = true
    /// Draw switched-off layers as faint ghosts instead of hiding them outright.
    var ghostHiddenLayers = false
    /// 0 = assembled, 1 = layers pulled apart along the build-up normal.
    var explode: Double = 0
}

/// Standard shop-drawing viewpoints.
enum ViewPreset: String, CaseIterable, Identifiable {
    case iso = "Iso"
    case front = "Ansicht"
    case back = "Rückseite"
    case top = "Draufsicht"
    case side = "Seitlich"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .iso:   return "cube"
        case .front: return "rectangle"
        case .back:  return "rectangle.on.rectangle"
        case .top:   return "square.split.1x2"
        case .side:  return "rectangle.portrait"
        }
    }

    /// Camera direction in scene space (Y up, model centred at the origin).
    var direction: SIMD3<Float> {
        switch self {
        case .iso:   return simd_normalize(SIMD3(-0.75, 0.55, -1))
        case .front: return SIMD3(0, 0, -1)
        case .back:  return SIMD3(0, 0, 1)
        case .top:   return SIMD3(0, 1, 0)
        case .side:  return SIMD3(1, 0, 0)
        }
    }

    var up: SIMD3<Float> {
        self == .top ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
    }
}

/// Builds and maintains the SceneKit scene for one BTLX document.
///
/// BTLX is millimetre based and Z-up; SceneKit wants metres and Y-up. Both conversions
/// live on a single orientation node so part nodes keep their original BTLX transform
/// and stay directly comparable with the numbers shown in the inspector.
final class ModelScene {

    let scene = SCNScene()
    let document: BTLxDocument

    private let orientationNode = SCNNode()   // mm -> m, Z-up -> Y-up
    private let centeringNode = SCNNode()     // model centre -> origin
    private var partNodes: [Int: SCNNode] = [:]
    private var edgeNodes: [Int: SCNNode] = [:]
    private var layerOfPart: [Int: String] = [:]

    /// Metres per millimetre.
    private static let unitScale: Float = 0.001

    init(document: BTLxDocument) {
        self.document = document
        buildHierarchy()
        buildParts()
        buildLighting()
    }

    /// All part nodes, for camera framing.
    var allPartNodes: [SCNNode] { Array(partNodes.values) }

    func nodes(forLayers layers: Set<String>) -> [SCNNode] {
        partNodes.compactMap { id, node in
            layers.contains(layerOfPart[id] ?? "") ? node : nil
        }
    }

    // MARK: - Build

    private func buildHierarchy() {
        // -90° about X maps BTLX (x, y, z) to scene (x, z, -y): Z-up becomes Y-up.
        orientationNode.simdScale = SIMD3(repeating: Self.unitScale)
        orientationNode.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))

        let centre = document.bounds.isEmpty ? .zero : document.bounds.center
        centeringNode.simdPosition = -SIMD3<Float>(Float(centre.x), Float(centre.y), Float(centre.z))

        orientationNode.addChildNode(centeringNode)
        scene.rootNode.addChildNode(orientationNode)
    }

    private func buildParts() {
        for part in document.parts {
            layerOfPart[part.id] = part.layerID

            let node = SCNNode()
            node.name = "part-\(part.id)"
            node.simdTransform = float4x4(
                SIMD4(SIMD3<Float>(part.xAxis), 0),
                SIMD4(SIMD3<Float>(part.yAxis), 0),
                SIMD4(SIMD3<Float>(part.zAxis), 0),
                SIMD4(SIMD3<Float>(part.origin), 1)
            )

            if let geometry = GeometryFactory.solid(from: part.mesh) {
                geometry.firstMaterial = makeMaterial(for: part)
                node.geometry = geometry
            }

            if let edges = GeometryFactory.edges(from: part.mesh) {
                let edgeMaterial = SCNMaterial()
                edgeMaterial.lightingModel = .constant
                edgeMaterial.diffuse.contents = UIColor(white: 0.13, alpha: 1)
                edgeMaterial.writesToDepthBuffer = false
                edgeMaterial.readsFromDepthBuffer = true
                edges.firstMaterial = edgeMaterial

                let edgeNode = SCNNode(geometry: edges)
                edgeNode.name = "edges-\(part.id)"
                edgeNode.renderingOrder = 10
                node.addChildNode(edgeNode)
                edgeNodes[part.id] = edgeNode
            }

            centeringNode.addChildNode(node)
            partNodes[part.id] = node
        }
    }

    private func makeMaterial(for part: BTLxPart) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(layerColour(for: part))
        material.roughness.contents = 0.85
        material.metalness.contents = 0.0
        material.isDoubleSided = true
        return material
    }

    private func layerColour(for part: BTLxPart) -> SIMD4<Double> {
        document.layers.first { $0.id == part.layerID }?.colour
            ?? part.colour
            ?? SIMD4(0.72, 0.72, 0.72, 1)
    }

    private func buildLighting() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 520
        ambient.light?.color = UIColor(white: 1.0, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 780
        key.light?.castsShadow = false
        key.simdOrientation = simd_quatf(angle: -.pi / 4, axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: .pi / 5, axis: SIMD3(0, 1, 0))
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 340
        fill.simdOrientation = simd_quatf(angle: .pi * 0.8, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: -.pi / 8, axis: SIMD3(1, 0, 0))
        scene.rootNode.addChildNode(fill)
    }

    // MARK: - Display

    func apply(_ state: DisplayState) {
        let axis = document.normalAxis
        let centre = document.bounds.isEmpty ? SIMD3<Double>.zero : document.bounds.center
        let spread = Swift.max(document.bounds.size.x, document.bounds.size.z) * 0.35

        for part in document.parts {
            guard let node = partNodes[part.id] else { continue }
            let isVisible = state.visibleLayers.contains(part.layerID)
            let isSelected = state.selectedPartID == part.id

            node.isHidden = !isVisible && !state.ghostHiddenLayers
            edgeNodes[part.id]?.isHidden = !state.showEdges || (!isVisible && state.ghostHiddenLayers)

            if let material = node.geometry?.firstMaterial {
                let base = layerColour(for: part)
                let colour = UIColor(base)
                if isSelected {
                    material.diffuse.contents = colour
                    material.emission.contents = UIColor(red: 0.10, green: 0.42, blue: 0.85, alpha: 1)
                    material.emission.intensity = 0.45
                    material.transparency = 1
                } else {
                    material.diffuse.contents = colour
                    material.emission.contents = UIColor.black
                    material.emission.intensity = 0
                    material.transparency = isVisible ? 1 : 0.10
                }
            }

            // Pull each layer away from the model centre along the build-up normal.
            var offset = SIMD3<Double>.zero
            if state.explode > 0 {
                let layerCentre = (part.worldBounds.min[axis] + part.worldBounds.max[axis]) / 2
                offset[axis] = (layerCentre - centre[axis]) / Swift.max(document.bounds.size[axis], 1)
                    * spread * state.explode * 2
            }
            node.simdPosition = SIMD3<Float>(part.origin + offset)
        }
    }

    /// The part behind a tap, or nil when the user tapped empty space.
    func partID(for hit: SCNHitTestResult) -> Int? {
        var node: SCNNode? = hit.node
        while let candidate = node {
            if let name = candidate.name, name.hasPrefix("part-") {
                return Int(name.dropFirst("part-".count))
            }
            node = candidate.parent
        }
        return nil
    }
}

// MARK: - Colour bridging

extension UIColor {
    convenience init(_ v: SIMD4<Double>) {
        self.init(red: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: CGFloat(v.w))
    }
}

extension Color {
    init(_ v: SIMD4<Double>) {
        self.init(red: v.x, green: v.y, blue: v.z, opacity: v.w)
    }
}

extension SIMD3 where Scalar == Float {
    init(_ v: SIMD3<Double>) {
        self.init(Float(v.x), Float(v.y), Float(v.z))
    }
}
