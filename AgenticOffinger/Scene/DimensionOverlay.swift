import Foundation
import SceneKit
import UIKit
import simd

/// Builds the shop-drawing dimension overlay for the visible parts.
///
/// The overlay is a flat drawing laid into the plane of the element, just in front of
/// its outer face, so it stays aligned with the geometry while the model is orbited.
/// It carries what a production drawing carries: a dimension chain along each in-plane
/// axis with a tick at every part boundary, the overall dimension outside it, and a
/// label per part with its position number, designation and visible face size.
enum DimensionOverlay {

    // Colours follow the reference drawing: dimensioning in graphite, part labels in cyan.
    private static let lineColour = UIColor(white: 0.18, alpha: 1)
    private static let extensionColour = UIColor(white: 0.55, alpha: 1)
    private static let textColour = UIColor(white: 0.12, alpha: 1)
    private static let labelColour = UIColor(red: 0, green: 0.60, blue: 0.83, alpha: 1)

    /// Boundaries closer together than this are treated as one station, in millimetres.
    private static let stationTolerance = 0.5

    static func make(document: BTLxDocument, visibleLayers: Set<String>) -> SCNNode {
        let root = SCNNode()
        root.name = "dimensions"

        let parts = document.parts.filter { visibleLayers.contains($0.layerID) }
        guard !parts.isEmpty else { return root }

        var bounds = BoundingBox.empty
        for part in parts { bounds.formUnion(part.worldBounds) }
        let size = bounds.size

        // Drawing plane: spanned by the two in-plane axes, offset off the outer face.
        let normal = document.normalAxis
        let inPlane = [0, 1, 2].filter { $0 != normal }
        let hAxis = size[inPlane[0]] >= size[inPlane[1]] ? inPlane[0] : inPlane[1]
        let vAxis = inPlane[0] == hAxis ? inPlane[1] : inPlane[0]

        let span = Swift.max(size[hAxis], size[vAxis], 1)
        let plane = Plane(hAxis: hAxis,
                          vAxis: vAxis,
                          normalAxis: normal,
                          coordinate: bounds.max[normal] + span * 0.012)

        let fontSize = span / 48
        let chainGap = span * 0.055        // model edge -> part chain
        let overallGap = span * 0.125      // model edge -> overall dimension
        let tick = fontSize * 0.55

        var lines = LineBuilder()
        var dashes = LineBuilder()

        // Horizontal chain, above the element.
        chain(stations: stations(of: parts, axis: hAxis),
              from: bounds.max[vAxis], gap: chainGap, tick: tick, fontSize: fontSize,
              horizontal: true, plane: plane, root: root, lines: &lines, dashes: &dashes)

        // Vertical chain, to the leading side of the element.
        chain(stations: stations(of: parts, axis: vAxis),
              from: bounds.min[hAxis], gap: -chainGap, tick: tick, fontSize: fontSize,
              horizontal: false, plane: plane, root: root, lines: &lines, dashes: &dashes)

        // Overall dimensions outside both chains.
        overall(from: bounds.min[hAxis], to: bounds.max[hAxis],
                at: bounds.max[vAxis] + overallGap, tick: tick, fontSize: fontSize,
                horizontal: true, plane: plane, root: root, lines: &lines)
        overall(from: bounds.min[vAxis], to: bounds.max[vAxis],
                at: bounds.min[hAxis] - overallGap, tick: tick, fontSize: fontSize,
                horizontal: false, plane: plane, root: root, lines: &lines)

        // One label per visible part.
        for part in parts {
            label(for: part, hAxis: hAxis, vAxis: vAxis, normalAxis: normal,
                  lift: span * 0.003, fontSize: fontSize, plane: plane, root: root)
        }

        if let geometry = lines.geometry(colour: lineColour) {
            root.addChildNode(SCNNode(geometry: geometry))
        }
        if let geometry = dashes.geometry(colour: extensionColour) {
            root.addChildNode(SCNNode(geometry: geometry))
        }
        return root
    }

    // MARK: - Plane

    /// The drawing plane, plus the basis that makes text read correctly when the
    /// element is seen from its outer face.
    private struct Plane {
        let hAxis: Int
        let vAxis: Int
        let normalAxis: Int
        let coordinate: Double

        func point(_ h: Double, _ v: Double) -> SIMD3<Double> {
            point(h, v, depth: coordinate)
        }

        func point(_ h: Double, _ v: Double, depth: Double) -> SIMD3<Double> {
            var p = SIMD3<Double>.zero
            p[hAxis] = h
            p[vAxis] = v
            p[normalAxis] = depth
            return p
        }

        private func unit(_ axis: Int) -> SIMD3<Double> {
            var v = SIMD3<Double>.zero
            v[axis] = 1
            return v
        }

        /// Viewed from the outer face, this is the direction text runs.
        var orientation: simd_quatf {
            let n = unit(normalAxis)
            let up = unit(vAxis)
            let right = simd_cross(up, n)
            return simd_quatf(simd_float3x3(SIMD3<Float>(right), SIMD3<Float>(up), SIMD3<Float>(n)))
        }
    }

    // MARK: - Chains

    private static func stations(of parts: [BTLxPart], axis: Int) -> [Double] {
        var values: [Double] = []
        for part in parts {
            values.append(part.worldBounds.min[axis])
            values.append(part.worldBounds.max[axis])
        }
        values.sort()
        var merged: [Double] = []
        for value in values where (merged.last.map { value - $0 > stationTolerance } ?? true) {
            merged.append(value)
        }
        return merged
    }

    /// A dimension chain: extension lines out to the dimension line, a tick at every
    /// station and the distance between neighbouring stations written above the segment.
    private static func chain(stations: [Double],
                              from edge: Double,
                              gap: Double,
                              tick: Double,
                              fontSize: Double,
                              horizontal: Bool,
                              plane: Plane,
                              root: SCNNode,
                              lines: inout LineBuilder,
                              dashes: inout LineBuilder) {
        guard stations.count >= 2 else { return }
        let line = edge + gap

        func at(_ station: Double, _ offset: Double) -> SIMD3<Double> {
            horizontal ? plane.point(station, offset) : plane.point(offset, station)
        }

        lines.add(at(stations[0], line), at(stations[stations.count - 1], line))

        for station in stations {
            dashes.addDashed(at(station, edge), at(station, line + (gap > 0 ? tick : -tick)),
                             dash: tick * 1.2)
            // 45° slash tick, the way a dimension line is ticked on a shop drawing.
            lines.add(at(station - tick * 0.5, line - tick * 0.5),
                      at(station + tick * 0.5, line + tick * 0.5))
        }

        for i in 0..<(stations.count - 1) {
            let length = stations[i + 1] - stations[i]
            guard length > stationTolerance else { continue }
            let middle = (stations[i] + stations[i + 1]) / 2
            let offset = line + (gap > 0 ? fontSize * 0.55 : -fontSize * 0.55)
            let node = text(Format.mm(length),
                            size: fontSize * (length < fontSize * 2.2 ? 0.62 : 1),
                            colour: textColour,
                            at: at(middle, offset),
                            plane: plane,
                            rotated: !horizontal)
            root.addChildNode(node)
        }
    }

    private static func overall(from start: Double,
                                to end: Double,
                                at offset: Double,
                                tick: Double,
                                fontSize: Double,
                                horizontal: Bool,
                                plane: Plane,
                                root: SCNNode,
                                lines: inout LineBuilder) {
        func at(_ station: Double, _ across: Double) -> SIMD3<Double> {
            horizontal ? plane.point(station, across) : plane.point(across, station)
        }
        lines.add(at(start, offset), at(end, offset))
        for station in [start, end] {
            lines.add(at(station - tick * 0.5, offset - tick * 0.5),
                      at(station + tick * 0.5, offset + tick * 0.5))
        }
        let node = text(Format.mm(end - start),
                        size: fontSize * 1.15,
                        colour: textColour,
                        at: at((start + end) / 2, offset + (horizontal ? 1 : -1) * fontSize * 0.65),
                        plane: plane,
                        rotated: !horizontal)
        root.addChildNode(node)
    }

    // MARK: - Part labels

    private static func label(for part: BTLxPart,
                              hAxis: Int,
                              vAxis: Int,
                              normalAxis: Int,
                              lift: Double,
                              fontSize: Double,
                              plane: Plane,
                              root: SCNNode) {
        let width = part.worldBounds.size[hAxis]
        let height = part.worldBounds.size[vAxis]
        guard Swift.min(width, height) > 1 else { return }

        // Narrow members carry their label turned along their length, as on the drawing;
        // the caption keeps its size and is allowed to overhang a slender stud rather
        // than shrinking to something unreadable.
        let rotated = height > width
        let size = fontSize * 0.8
        let position = plane.point(part.worldBounds.center[hAxis],
                                   part.worldBounds.center[vAxis],
                                   depth: part.worldBounds.max[normalAxis] + lift)
        let caption = "\(part.listLabel)\n\(Format.mm(width)) × \(Format.mm(height)) mm"

        root.addChildNode(text(caption, size: size, colour: labelColour, at: position,
                               plane: plane, rotated: rotated, weight: .semibold,
                               occludable: true))
    }

    // MARK: - Text

    private static func text(_ string: String,
                             size: Double,
                             colour: UIColor,
                             at position: SIMD3<Double>,
                             plane: Plane,
                             rotated: Bool,
                             weight: UIFont.Weight = .medium,
                             occludable: Bool = false) -> SCNNode {
        let geometry = SCNText(string: string, extrusionDepth: 0)
        geometry.font = UIFont.systemFont(ofSize: CGFloat(size), weight: weight)
        geometry.flatness = CGFloat(Swift.max(size * 0.01, 0.05))
        geometry.alignmentMode = CATextLayerAlignmentMode.center.rawValue
        geometry.isWrapped = false

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = colour
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = occludable
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 20

        // SCNText grows from its own baseline origin; recentre it on the anchor point.
        let (minBound, maxBound) = geometry.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((minBound.x + maxBound.x) / 2,
                                               (minBound.y + maxBound.y) / 2,
                                               0)
        node.simdPosition = SIMD3<Float>(position)
        node.simdOrientation = rotated
            ? plane.orientation * simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
            : plane.orientation
        return node
    }
}

// MARK: - Line building

/// Accumulates line segments into a single `.line` geometry, so the whole drawing
/// costs one draw call rather than one per segment.
private struct LineBuilder {
    private var points: [SCNVector3] = []
    private var indices: [Int32] = []

    mutating func add(_ a: SIMD3<Double>, _ b: SIMD3<Double>) {
        for p in [a, b] {
            indices.append(Int32(points.count))
            points.append(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
        }
    }

    mutating func addDashed(_ a: SIMD3<Double>, _ b: SIMD3<Double>, dash: Double) {
        let total = simd_distance(a, b)
        guard total > 0, dash > 0 else { return }
        let steps = Swift.max(Int(total / (dash * 2)), 1)
        let step = 1.0 / Double(steps)
        for i in 0..<steps {
            let t0 = Double(i) * step
            let t1 = t0 + step * 0.55
            add(a + (b - a) * t0, a + (b - a) * t1)
        }
    }

    func geometry(colour: UIColor) -> SCNGeometry? {
        guard !points.isEmpty else { return nil }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points)],
                                   elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = colour
        material.writesToDepthBuffer = false
        geometry.firstMaterial = material
        return geometry
    }
}
