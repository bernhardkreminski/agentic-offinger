import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// BTLX (Bureau Timber Language, design2machine). Declared in Info.plist so the app
    /// also shows up in the Files "Öffnen mit" list; the fallbacks keep the picker usable
    /// if the declaration is ever missing.
    static let btlx: UTType = UTType("com.design2machine.btlx")
        ?? UTType(filenameExtension: "btlx", conformingTo: .xml)
        ?? .xml
}

@Observable
final class AppModel {

    /// The file shipped in the bundle, opened on launch and via "Beispiel laden".
    static let sampleFileName = "RoWaPla Musterwand V3"

    private(set) var document: BTLxDocument?
    private(set) var modelScene: ModelScene?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    var display = DisplayState()
    var preset: ViewPreset = .iso
    var frameRequest = 0
    var showsInspector = false

    init() {
        loadSample()
    }

    // MARK: - Loading

    func loadSample() {
        guard let url = Bundle.main.url(forResource: Self.sampleFileName, withExtension: "btlx") else {
            errorMessage = "Die Beispieldatei „\(Self.sampleFileName).btlx“ ist nicht im App-Bundle enthalten."
            return
        }
        load(url: url)
    }

    func load(url: URL) {
        isLoading = true
        errorMessage = nil
        do {
            let parsed = try BTLxParser.parse(url: url)
            adopt(parsed)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            load(url: url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func adopt(_ parsed: BTLxDocument) {
        document = parsed
        modelScene = ModelScene(document: parsed)
        // Every layer on by default — RW and BS1 are meant to be readable together.
        display = DisplayState(visibleLayers: Set(parsed.layers.map(\.id)))
        preset = .iso
        frameRequest += 1
        showsInspector = false
    }

    func dismissError() { errorMessage = nil }

    // MARK: - Layers

    var layers: [BuildUpLayer] { document?.layers ?? [] }

    func isVisible(_ layer: BuildUpLayer) -> Bool {
        display.visibleLayers.contains(layer.id)
    }

    func toggle(_ layer: BuildUpLayer) {
        if display.visibleLayers.contains(layer.id) {
            display.visibleLayers.remove(layer.id)
            // Do not leave a selection stranded on a switched-off layer.
            if let id = display.selectedPartID,
               document?.part(id: id)?.layerID == layer.id {
                display.selectedPartID = nil
                showsInspector = false
            }
        } else {
            display.visibleLayers.insert(layer.id)
        }
    }

    /// Show this layer only — the "Einzelschicht" case.
    func isolate(_ layer: BuildUpLayer) {
        display.visibleLayers = [layer.id]
        frameRequest += 1
    }

    func showAllLayers() {
        display.visibleLayers = Set(layers.map(\.id))
        frameRequest += 1
    }

    var allLayersVisible: Bool {
        !layers.isEmpty && display.visibleLayers.count == layers.count
    }

    // MARK: - Selection

    var selectedPart: BTLxPart? {
        guard let id = display.selectedPartID else { return nil }
        return document?.part(id: id)
    }

    func select(partID: Int?) {
        display.selectedPartID = partID
        showsInspector = partID != nil
    }

    func parts(in layer: BuildUpLayer) -> [BTLxPart] {
        document?.parts(in: layer) ?? []
    }

    // MARK: - Camera

    func apply(preset: ViewPreset) {
        self.preset = preset
        frameRequest += 1
    }

    func refit() { frameRequest += 1 }
}

// MARK: - Layer summaries

extension BuildUpLayer {
    func summary(in document: BTLxDocument) -> LayerSummary {
        let parts = document.parts(in: self)
        let materials = Array(Set(parts.map(\.material))).filter { !$0.isEmpty }.sorted()
        return LayerSummary(partCount: parts.count,
                            totalWeight: parts.reduce(0) { $0 + $1.weight * Double($1.count) },
                            materials: materials,
                            designations: Array(Set(parts.map(\.designation))).sorted())
    }
}

struct LayerSummary {
    var partCount: Int
    var totalWeight: Double
    var materials: [String]
    var designations: [String]
}
