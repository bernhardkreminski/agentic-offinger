import Foundation
import simd

/// Derives build-up layers (Schichtaufbau) from part geometry.
///
/// BTLX has no layer attribute, so layers are reconstructed the way a timber-frame
/// element is actually built: parts are projected onto the element normal — the
/// thinnest of the three world axes — and grouped into bands of overlapping extent.
///
/// The band holding the structural framing (the thickest band of solid timber) becomes
/// **RW** (Rahmenwerk). Bands stacked outwards from it become **BS1, BS2 …**
/// (Beplankung Seite 1 …), bands on the opposite face **IS1, IS2 …** (Innenseite).
enum LayerClassifier {

    struct Result {
        var parts: [BTLxPart]
        var layers: [BuildUpLayer]
        var normalAxis: Int
    }

    /// Two bands are merged when they overlap by more than this, in millimetres.
    private static let overlapTolerance = 1.0

    static func classify(parts: [BTLxPart], modelBounds: BoundingBox) -> Result {
        guard !parts.isEmpty, !modelBounds.isEmpty else {
            return Result(parts: parts, layers: [], normalAxis: 1)
        }

        let axis = normalAxis(of: modelBounds)
        let bands = bands(for: parts, axis: axis)
        guard !bands.isEmpty else { return Result(parts: parts, layers: [], normalAxis: axis) }

        let frameIndex = frameBandIndex(bands, parts: parts)
        let layers = name(bands, frameIndex: frameIndex)

        var byPart: [Int: String] = [:]
        for layer in layers {
            for partID in layer.partIDs { byPart[partID] = layer.id }
        }
        var assigned = parts
        for i in assigned.indices { assigned[i].layerID = byPart[assigned[i].id] ?? "" }

        return Result(parts: assigned, layers: layers, normalAxis: axis)
    }

    // MARK: - Steps

    /// The element normal is the world axis the model is thinnest along — for a wall
    /// panel that is the wall thickness.
    private static func normalAxis(of bounds: BoundingBox) -> Int {
        let size = bounds.size
        var axis = 0
        for i in 1..<3 where size[i] < size[axis] { axis = i }
        return axis
    }

    private struct Band {
        var lower: Double
        var upper: Double
        var partIDs: [Int]
    }

    /// Sweep the parts along the normal and merge those whose extents overlap.
    private static func bands(for parts: [BTLxPart], axis: Int) -> [Band] {
        let sorted = parts.sorted { $0.worldBounds.min[axis] < $1.worldBounds.min[axis] }
        var bands: [Band] = []

        for part in sorted {
            let lower = part.worldBounds.min[axis]
            let upper = part.worldBounds.max[axis]
            if var last = bands.last, lower < last.upper - overlapTolerance {
                last.upper = Swift.max(last.upper, upper)
                last.partIDs.append(part.id)
                bands[bands.count - 1] = last
            } else {
                bands.append(Band(lower: lower, upper: upper, partIDs: [part.id]))
            }
        }
        return bands
    }

    /// The framing band is the thickest one — sheathing and insulation are always
    /// thinner than the studs they are fixed to. Ties break on total weight.
    private static func frameBandIndex(_ bands: [Band], parts: [BTLxPart]) -> Int {
        let weights = Dictionary(uniqueKeysWithValues: parts.map { ($0.id, $0.weight) })
        var best = 0
        var bestKey = (thickness: -Double.infinity, weight: -Double.infinity)
        for (i, band) in bands.enumerated() {
            let thickness = band.upper - band.lower
            let weight = band.partIDs.reduce(0.0) { $0 + (weights[$1] ?? 0) }
            if thickness > bestKey.thickness + 0.5
                || (abs(thickness - bestKey.thickness) <= 0.5 && weight > bestKey.weight) {
                best = i
                bestKey = (thickness, weight)
            }
        }
        return best
    }

    private static func name(_ bands: [Band], frameIndex: Int) -> [BuildUpLayer] {
        bands.enumerated().map { index, band in
            let code: String
            let name: String
            if index == frameIndex {
                code = "RW"
                name = "Rahmenwerk"
            } else if index > frameIndex {
                let n = index - frameIndex
                code = "BS\(n)"
                name = "Beplankung Seite \(n)"
            } else {
                let n = frameIndex - index
                code = "IS\(n)"
                name = "Innenseite \(n)"
            }
            return BuildUpLayer(id: code,
                                name: name,
                                partIDs: band.partIDs.sorted(),
                                normalRange: band.lower...band.upper,
                                colour: palette(for: code, index: index))
        }
    }

    /// Muted shop-drawing colours: framing in structural timber, sheathing in panel tones.
    private static func palette(for code: String, index: Int) -> SIMD4<Double> {
        if code == "RW" { return SIMD4(0.78, 0.58, 0.33, 1) }        // Nadelholz
        let tones: [SIMD4<Double>] = [
            SIMD4(0.42, 0.62, 0.76, 1),   // BS1 / IS1
            SIMD4(0.55, 0.72, 0.52, 1),
            SIMD4(0.80, 0.55, 0.55, 1),
            SIMD4(0.66, 0.58, 0.78, 1)
        ]
        return tones[abs(index) % tones.count]
    }
}
