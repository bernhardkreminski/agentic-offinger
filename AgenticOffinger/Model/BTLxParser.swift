import Foundation
import simd

enum BTLxParseError: LocalizedError {
    case unreadable(String)
    case malformed(String)
    case noParts

    var errorDescription: String? {
        switch self {
        case .unreadable(let why):  return "Die Datei konnte nicht gelesen werden. (\(why))"
        case .malformed(let why):   return "Die BTLX-Datei ist fehlerhaft. (\(why))"
        case .noParts:              return "Die BTLX-Datei enthält keine Bauteile."
        }
    }
}

/// Streaming BTLX reader built on Foundation's `XMLParser`.
///
/// BTLX is namespaced XML (`https://www.design2machine.com`); the parser runs with
/// namespace processing on and matches on local element names only, so files written
/// with any prefix — or none — parse identically.
final class BTLxParser: NSObject {

    static func parse(url: URL) throws -> BTLxDocument {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw BTLxParseError.unreadable(error.localizedDescription) }
        return try parse(data: data, fileName: url.lastPathComponent)
    }

    static func parse(data: Data, fileName: String) throws -> BTLxDocument {
        let reader = BTLxParser(fileName: fileName)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse() else {
            let why = parser.parserError?.localizedDescription ?? "unbekannter XML-Fehler"
            throw BTLxParseError.malformed(why)
        }
        guard !reader.parts.isEmpty else { throw BTLxParseError.noParts }
        return reader.makeDocument()
    }

    // MARK: - State

    private let fileName: String
    private var version = ""
    private var language = ""
    private var projectName = ""
    private var sourceFile = ""
    private var history = FileHistory()
    private var parts: [BTLxPart] = []

    /// Element names whose character data we collect (processing parameters).
    private var text = ""
    private var captureText = false

    private var current: PartBuilder?
    /// Nesting guard: `<Position>` appears inside `<Transformation>`, `<UserReferencePlane>` and others.
    private var elementStack: [String] = []
    private var currentProcessing: Processing?

    private init(fileName: String) {
        self.fileName = fileName
    }

    /// Mutable scratch space while a `<Part>` element is open.
    private struct PartBuilder {
        var attributes: [String: String]
        var origin = SIMD3<Double>(0, 0, 0)
        var xAxis = SIMD3<Double>(1, 0, 0)
        var yAxis = SIMD3<Double>(0, 1, 0)
        var haveTransform = false
        var centerOfGravity: SIMD3<Double>?
        var colour: SIMD4<Double>?
        var referenceSide: String?
        var referenceSideAlign: String?
        var mesh = Mesh()
        var processings: [Processing] = []
    }

    // MARK: - Document assembly

    private func makeDocument() -> BTLxDocument {
        var bounds = BoundingBox.empty
        for part in parts { bounds.formUnion(part.worldBounds) }

        let classified = LayerClassifier.classify(parts: parts, modelBounds: bounds)
        return BTLxDocument(fileName: fileName,
                            version: version,
                            language: language,
                            projectName: projectName,
                            sourceFile: sourceFile,
                            history: history,
                            parts: classified.parts,
                            layers: classified.layers,
                            normalAxis: classified.normalAxis,
                            bounds: bounds)
    }
}

// MARK: - XMLParserDelegate

extension BTLxParser: XMLParserDelegate {

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attr: [String: String]) {

        elementStack.append(elementName)

        switch elementName {
        case "BTLx":
            version = attr["Version"] ?? ""
            language = attr["Language"] ?? ""

        case "InitialExportProgram":
            history = FileHistory(programName: attr["ProgramName"] ?? "",
                                  programVersion: attr["ProgramVersion"] ?? "",
                                  companyName: attr["CompanyName"] ?? "",
                                  userName: attr["UserName"] ?? "",
                                  computerName: attr["ComputerName"] ?? "",
                                  date: attr["Date"] ?? "",
                                  time: attr["Time"] ?? "",
                                  sourceFileName: attr["FileName"] ?? "",
                                  comment: attr["Comment"] ?? "")

        case "Project":
            projectName = attr["Name"] ?? ""
            sourceFile = attr["SourceFile"] ?? ""

        case "Part":
            current = PartBuilder(attributes: attr)

        case "Transformation":
            current?.attributes["GUID"] = attr["GUID"] ?? current?.attributes["GUID"] ?? ""

        case "ReferencePoint" where isInsideTransformation:
            current?.origin = vector(attr)
            current?.haveTransform = true

        case "XVector" where isInsideTransformation:
            current?.xAxis = vector(attr)

        case "YVector" where isInsideTransformation:
            current?.yAxis = vector(attr)

        case "CenterOfGravity":
            current?.centerOfGravity = vector(attr)

        case "Colour":
            // BTLX writes 0...255 channels and a 0...100 transparency percentage.
            let r = double(attr["Red"]) / 255, g = double(attr["Green"]) / 255, b = double(attr["Blue"]) / 255
            let transparency = attr["Transparency"].map { Double($0) ?? 0 } ?? 0
            current?.colour = SIMD4(r, g, b, 1 - min(max(transparency, 0), 100) / 100)

        case "ReferenceSide":
            current?.referenceSide = attr["Side"]
            current?.referenceSideAlign = attr["Align"]

        case "IndexedFaceSet":
            current?.mesh.faces = Self.parseFaces(attr["coordIndex"] ?? "")

        case "Coordinate":
            current?.mesh.points = Self.parsePoints(attr["point"] ?? "")

        default:
            if isProcessingElement(elementName) {
                currentProcessing = Processing(type: elementName,
                                               name: attr["Name"] ?? "",
                                               processID: attr["ProcessID"] ?? "",
                                               referencePlaneID: attr["ReferencePlaneID"] ?? "",
                                               quality: attr["ProcessingQuality"] ?? "",
                                               isActive: (attr["Process"] ?? "yes") == "yes",
                                               parameters: [])
            } else if currentProcessing != nil {
                // A parameter element such as <StartX> or <MachiningLimits …/>.
                captureText = true
                text = ""
                for (key, value) in attr.sorted(by: { $0.key < $1.key }) {
                    currentProcessing?.parameters.append((key: "\(elementName).\(key)", value: value))
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureText { text += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {

        defer { if elementStack.last == elementName { elementStack.removeLast() } }

        if elementName == "Part" {
            if let builder = current { parts.append(finish(builder, id: parts.count)) }
            current = nil
            return
        }

        if isProcessingElement(elementName) {
            if let processing = currentProcessing { current?.processings.append(processing) }
            currentProcessing = nil
            return
        }

        if captureText {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                currentProcessing?.parameters.append((key: elementName, value: trimmed))
            }
            captureText = false
            text = ""
        }
    }

    // MARK: - Helpers

    /// `<Position>` also appears under `<UserReferencePlane>`; only the one directly
    /// inside `<Transformation>` defines the part placement.
    private var isInsideTransformation: Bool {
        guard elementStack.count >= 3 else { return false }
        return elementStack[elementStack.count - 3] == "Transformation"
    }

    private func isProcessingElement(_ name: String) -> Bool {
        elementStack.count >= 2 && elementStack[elementStack.count - 2] == "Processings"
    }

    private func vector(_ attr: [String: String]) -> SIMD3<Double> {
        SIMD3(double(attr["X"]), double(attr["Y"]), double(attr["Z"]))
    }

    private func double(_ string: String?) -> Double {
        guard let string, let value = Double(string) else { return 0 }
        return value
    }

    private func finish(_ b: PartBuilder, id: Int) -> BTLxPart {
        let a = b.attributes
        var xAxis = b.xAxis, yAxis = b.yAxis
        if simd_length(xAxis) < 1e-9 { xAxis = SIMD3(1, 0, 0) }
        if simd_length(yAxis) < 1e-9 { yAxis = SIMD3(0, 1, 0) }
        xAxis = simd_normalize(xAxis)
        // Re-orthogonalise so a slightly off YVector cannot shear the mesh.
        yAxis = simd_normalize(yAxis - xAxis * simd_dot(xAxis, yAxis))
        let zAxis = simd_cross(xAxis, yAxis)

        var bounds = BoundingBox.empty
        for p in b.mesh.points {
            bounds.expand(b.origin + xAxis * p.x + yAxis * p.y + zAxis * p.z)
        }

        return BTLxPart(id: id,
                        singleMemberNumber: a["SingleMemberNumber"] ?? "",
                        designation: a["Designation"] ?? "—",
                        material: a["Material"] ?? "",
                        elementNumber: a["ElementNumber"] ?? "",
                        assemblyNumber: a["AssemblyNumber"] ?? "",
                        orderNumber: a["OrderNumber"] ?? "",
                        storey: a["Storey"] ?? "",
                        count: Int(a["Count"] ?? "1") ?? 1,
                        guid: (a["GUID"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "{}")),
                        length: double(a["Length"]),
                        width: double(a["Width"]),
                        height: double(a["Height"]),
                        weight: double(a["Weight"]),
                        origin: b.origin,
                        xAxis: xAxis,
                        yAxis: yAxis,
                        zAxis: zAxis,
                        centerOfGravity: b.centerOfGravity,
                        colour: b.colour,
                        referenceSide: b.referenceSide,
                        referenceSideAlign: b.referenceSideAlign,
                        mesh: b.mesh,
                        processings: b.processings,
                        worldBounds: bounds)
    }

    // MARK: - IndexedFaceSet

    /// `"0 1 2 3 -1 1 0 4 5 -1"` -> `[[0,1,2,3], [1,0,4,5]]`
    static func parseFaces(_ string: String) -> [[Int]] {
        var faces: [[Int]] = []
        var face: [Int] = []
        for token in string.split(whereSeparator: \.isWhitespace) {
            guard let index = Int(token) else { continue }
            if index < 0 {
                if face.count >= 3 { faces.append(face) }
                face.removeAll(keepingCapacity: true)
            } else {
                face.append(index)
            }
        }
        if face.count >= 3 { faces.append(face) }   // tolerate a missing trailing -1
        return faces
    }

    /// `"10 0 80 10 200 80"` -> `[(10,0,80), (10,200,80)]`
    static func parsePoints(_ string: String) -> [SIMD3<Double>] {
        var values: [Double] = []
        values.reserveCapacity(string.count / 4)
        for token in string.split(whereSeparator: \.isWhitespace) {
            values.append(Double(token) ?? 0)
        }
        var points: [SIMD3<Double>] = []
        points.reserveCapacity(values.count / 3)
        var i = 0
        while i + 2 < values.count {
            points.append(SIMD3(values[i], values[i + 1], values[i + 2]))
            i += 3
        }
        return points
    }
}
