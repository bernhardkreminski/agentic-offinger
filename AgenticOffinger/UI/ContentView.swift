import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @State private var model = AppModel()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isImporting = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LayerSidebar(model: model)
                .navigationTitle("Agentic Offinger")
                .navigationBarTitleDisplayMode(.inline)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [.btlx, .xml, .data],
                      allowsMultipleSelection: false) { result in
            model.handleImport(result)
        }
        .alert("Import fehlgeschlagen",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.dismissError() } })) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            if let scene = model.modelScene, let document = model.document {
                viewport(scene: scene, document: document)
            } else {
                ContentUnavailableView {
                    Label("Kein Modell geladen", systemImage: "cube.transparent")
                } description: {
                    Text("BTLX-Datei importieren, um mit der Arbeitsvorbereitung zu beginnen.")
                } actions: {
                    Button("BTLX importieren…") { isImporting = true }
                        .buttonStyle(.borderedProminent)
                    Button("Beispiel laden") { model.loadSample() }
                }
            }
        }
        .navigationTitle(model.document?.fileName ?? "Agentic Offinger")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .inspector(isPresented: $model.showsInspector) {
            PartInspector(model: model)
                .inspectorColumnWidth(min: 300, ideal: 330, max: 420)
        }
    }

    private func viewport(scene: ModelScene, document: BTLxDocument) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.94), Color(white: 0.82)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ModelSceneView(modelScene: scene,
                           display: model.display,
                           frameRequest: model.frameRequest,
                           preset: model.preset) { partID in
                model.select(partID: partID)
            }
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                ViewPresetBar(model: model)
                ActiveLayerChips(model: model, document: document)
                Spacer()
                ViewportLegend(document: document)
            }
            .padding(16)
            .allowsHitTesting(true)
        }
        .overlay(alignment: .bottomTrailing) {
            DisplayOptionsCard(model: model)
                .padding(16)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                isImporting = true
            } label: {
                Label("BTLX importieren", systemImage: "square.and.arrow.down")
            }

            Button {
                model.loadSample()
            } label: {
                Label("Beispiel laden", systemImage: "arrow.clockwise")
            }

            Button {
                model.refit()
            } label: {
                Label("Einpassen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(model.modelScene == nil)

            Button {
                model.showsInspector.toggle()
            } label: {
                Label("Bauteilinfo", systemImage: "sidebar.trailing")
            }
            .disabled(model.document == nil)
        }
    }
}

// MARK: - Viewport overlays

private struct ViewPresetBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ViewPreset.allCases) { preset in
                Button {
                    model.apply(preset: preset)
                } label: {
                    Label(preset.rawValue, systemImage: preset.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .background(model.preset == preset ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(model.preset == preset ? Color.accentColor : Color.primary)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }
}

/// The layers currently switched on — the "RW + BS1 at the same time" readout.
private struct ActiveLayerChips: View {
    @Bindable var model: AppModel
    let document: BTLxDocument

    var body: some View {
        let active = document.layers.filter { model.display.visibleLayers.contains($0.id) }
        HStack(spacing: 6) {
            Text("Sichtbar:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if active.isEmpty {
                Text("keine Schicht")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(active) { layer in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(layer.colour))
                        .frame(width: 8, height: 8)
                    Text(layer.id)
                        .font(.caption2.weight(.bold))
                        .monospaced()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
}

private struct ViewportLegend: View {
    let document: BTLxDocument

    var body: some View {
        let size = document.bounds.size
        VStack(alignment: .leading, spacing: 3) {
            Text(document.projectName.isEmpty ? document.fileName : document.projectName)
                .font(.caption.weight(.semibold))
            Text("\(Format.mm(size.x)) × \(Format.mm(size.y)) × \(Format.mm(size.z)) mm")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("\(document.parts.count) Bauteile · \(Format.kg(document.totalWeight)) · BTLX \(document.version)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
}

private struct DisplayOptionsCard: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Kanten", isOn: $model.display.showEdges)
            Toggle("Ausgeblendete als Geist", isOn: $model.display.ghostHiddenLayers)
            Toggle("Bemaßung", isOn: Binding(get: { model.display.showDimensions },
                                             set: { model.setDimensions($0) }))
            VStack(alignment: .leading, spacing: 2) {
                Text("Schichten trennen")
                    .font(.caption)
                Slider(value: $model.display.explode, in: 0...1)
                    .frame(width: 190)
            }
        }
        .font(.caption)
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .frame(width: 230)
    }
}

#Preview {
    ContentView()
}
