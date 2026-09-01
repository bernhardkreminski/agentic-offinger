import Foundation
import simd

// MARK: - Geometry primitives

/// Axis-aligned bounding box in millimetres.
struct BoundingBox {
    var min: SIMD3<Double>
    var max: SIMD3<Double>

    static let empty = BoundingBox(min: SIMD3(repeating: .greatestFiniteMagnitude),
                                   max: SIMD3(repeating: -.greatestFiniteMagnitude))

    var isEmpty: Bool { min.x > max.x }
    var size: SIMD3<Double> { isEmpty ? .zero : max - min }
    var center: SIMD3<Double> { isEmpty ? .zero : (min + max) / 2 }

    mutating func expand(_ p: SIMD3<Double>) {
        min = simd_min(min, p)
        max = simd_max(max, p)
    }

    mutating func formUnion(_ other: BoundingBox) {
        guard !other.isEmpty else { return }
        min = simd_min(min, other.min)
        max = simd_max(max, other.max)
    }
}

/// A polygon soup as delivered by a BTLX `<IndexedFaceSet>`, in part-local millimetres.
struct Mesh {
    var points: [SIMD3<Double>] = []
    /// Index loops, one per planar face. Faces may have any vertex count.
    var faces: [[Int]] = []

    var isEmpty: Bool { points.isEmpty || faces.isEmpty }
}

// MARK: - Processings

/// One machining operation (`JackRafterCut`, `Lap`, `Mortise`, …) attached to a part.
struct Processing: Identifiable {
    let id = UUID()
    /// The XML element name, e.g. `JackRafterCut`.
    var type: String
    /// The `Name` attribute — cadwork's German operation label, e.g. "Abschnitt".
    var name: String
    var processID: String
    var referencePlaneID: String
    var quality: String
    var isActive: Bool
    /// Child elements in document order: (`StartX`, "1370"), (`Depth`, "10"), …
    var parameters: [(key: String, value: String)]

    /// Human readable operation name, falling back to the raw element name.
    var displayName: String {
        Processing.germanNames[type] ?? type
    }

    static let germanNames: [String: String] = [
        "JackRafterCut": "Abschnitt",
        "Lap": "Blatt",
        "DoubleCut": "Doppelschnitt",
        "Drilling": "Bohrung",
        "Mortise": "Zapfenloch",
        "Tenon": "Zapfen",
        "House": "Versatz",
        "Pocket": "Tasche",
        "Slot": "Schlitz",
        "Marking": "Anriss",
        "Text": "Beschriftung",
        "FrenchRidgeLap": "Französisches Blatt",
        "ScarfJoint": "Stoß",
        "StepJoint": "Versatz",
        "LongitudinalCut": "Längsschnitt"
    ]
}

// MARK: - Part

/// A single `<Part>` from the BTLX file: attributes, placement, mesh and machining.
struct BTLxPart: Identifiable {
    let id: Int

    // Identification
    var singleMemberNumber: String   // production list / position number
    var designation: String
    var material: String
    var elementNumber: String
    var assemblyNumber: String
    var orderNumber: String
    var storey: String
    var count: Int
    var guid: String

    // Nominal dimensions in millimetres, as written by the CAD system
    var length: Double
    var width: Double
    var height: Double
    var weight: Double               // kg

    // Placement: local -> world, columns are the axes, origin is the reference point
    var origin: SIMD3<Double>
    var xAxis: SIMD3<Double>
    var yAxis: SIMD3<Double>
    var zAxis: SIMD3<Double>

    var centerOfGravity: SIMD3<Double>?
    var colour: SIMD4<Double>?       // r,g,b,alpha in 0...1
    var referenceSide: String?
    var referenceSideAlign: String?

    var mesh: Mesh
    var processings: [Processing]

    /// World-space bounds in millimetres.
    var worldBounds: BoundingBox
    /// Assigned by `LayerClassifier`.
    var layerID: String = ""

    /// A short label for lists: "12 · Ständer".
    var listLabel: String {
        singleMemberNumber.isEmpty ? designation : "\(singleMemberNumber) · \(designation)"
    }

    /// Cross section as "80 × 200 mm" using the nominal width/height attributes.
    var crossSection: String {
        "\(Format.mm(width)) × \(Format.mm(height)) mm"
    }

    func toWorld(_ p: SIMD3<Double>) -> SIMD3<Double> {
        origin + xAxis * p.x + yAxis * p.y + zAxis * p.z
    }

    var centerOfGravityWorld: SIMD3<Double>? {
        centerOfGravity.map(toWorld)
    }
}

// MARK: - Layer

/// A build-up layer (Schichtaufbau) derived from the parts' position along the wall normal.
struct BuildUpLayer: Identifiable {
    /// Short code shown in the UI: "RW", "BS1", "IS1".
    var id: String
    /// Long German name: "Rahmenwerk", "Beplankung Seite 1".
    var name: String
    var partIDs: [Int]
    /// Extent along the build-up normal, millimetres.
    var normalRange: ClosedRange<Double>
    var colour: SIMD4<Double>

    var thickness: Double { normalRange.upperBound - normalRange.lowerBound }
}

// MARK: - Document

struct FileHistory {
    var programName = ""
    var programVersion = ""
    var companyName = ""
    var userName = ""
    var computerName = ""
    var date = ""
    var time = ""
    var sourceFileName = ""
    var comment = ""
}

/// The parsed BTLX file plus everything derived from it.
struct BTLxDocument {
    var fileName: String
    var version: String
    var language: String
    var projectName: String
    var sourceFile: String
    var history: FileHistory
    var parts: [BTLxPart]
    var layers: [BuildUpLayer]
    /// Index of the world axis the build-up is stacked along (0 = X, 1 = Y, 2 = Z).
    var normalAxis: Int
    var bounds: BoundingBox

    static let axisNames = ["X", "Y", "Z"]

    var totalWeight: Double { parts.reduce(0) { $0 + $1.weight * Double($1.count) } }

    func part(id: Int) -> BTLxPart? { parts.first { $0.id == id } }

    func parts(in layer: BuildUpLayer) -> [BTLxPart] {
        layer.partIDs.compactMap { part(id: $0) }
    }
}

// MARK: - Formatting helpers

enum Format {
    static func mm(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.0005
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    static func kg(_ value: Double) -> String { String(format: "%.2f kg", value) }

    static func point(_ p: SIMD3<Double>) -> String {
        "X \(mm(p.x))  Y \(mm(p.y))  Z \(mm(p.z))"
    }

    static func metre(_ mmValue: Double) -> String {
        String(format: "%.3f m", mmValue / 1000)
    }
}
