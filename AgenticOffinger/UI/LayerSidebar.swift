import SwiftUI

/// Layer browser: switch build-up layers on and off — several at once — and drill
/// into the parts each one contains.
struct LayerSidebar: View {

    @Bindable var model: AppModel
    @State private var expandedLayers: Set<String> = []

    var body: some View {
        List {
            if let document = model.document {
                layerSection(document)
                modelSection(document)
            } else {
                Text("Kein Modell geladen")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            if expandedLayers.isEmpty, let first = model.layers.first {
                expandedLayers.insert(first.id)
            }
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private func layerSection(_ document: BTLxDocument) -> some View {
        Section {
            ForEach(document.layers) { layer in
                LayerRow(model: model,
                         layer: layer,
                         summary: layer.summary(in: document),
                         isExpanded: expandedLayers.contains(layer.id)) {
                    if expandedLayers.contains(layer.id) {
                        expandedLayers.remove(layer.id)
                    } else {
                        expandedLayers.insert(layer.id)
                    }
                }

                if expandedLayers.contains(layer.id) {
                    ForEach(model.parts(in: layer)) { part in
                        PartRow(part: part,
                                isSelected: model.display.selectedPartID == part.id) {
                            if !model.isVisible(layer) { model.toggle(layer) }
                            model.select(partID: part.id)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Schichten")
                Spacer()
                Button(model.allLayersVisible ? "Nur \(model.layers.first?.id ?? "")" : "Alle") {
                    if model.allLayersVisible {
                        if let first = model.layers.first { model.isolate(first) }
                    } else {
                        model.showAllLayers()
                    }
                }
                .font(.caption)
                .textCase(nil)
                .disabled(model.layers.isEmpty)
            }
        } footer: {
            Text("Schichten sind aus der Bauteillage entlang der Elementnormale (Achse \(BTLxDocument.axisNames[document.normalAxis])) abgeleitet. Mehrere Schichten können gleichzeitig sichtbar sein.")
                .font(.caption2)
        }
    }

    // MARK: - Model metadata

    @ViewBuilder
    private func modelSection(_ document: BTLxDocument) -> some View {
        Section("Modell") {
            AttributeRow("Datei", document.fileName)
            if !document.projectName.isEmpty {
                AttributeRow("Projekt", document.projectName)
            }
            AttributeRow("BTLX-Version", document.version)
            AttributeRow("Bauteile", "\(document.parts.count)")
            AttributeRow("Gesamtgewicht", Format.kg(document.totalWeight))
            AttributeRow("Abmessung",
                         "\(Format.mm(document.bounds.size.x)) × \(Format.mm(document.bounds.size.y)) × \(Format.mm(document.bounds.size.z)) mm")
        }

        Section("Herkunft") {
            let history = document.history
            if !history.programName.isEmpty {
                AttributeRow("CAD", "\(history.programName) \(history.programVersion)")
            }
            if !history.companyName.isEmpty { AttributeRow("Hersteller", history.companyName) }
            if !history.userName.isEmpty { AttributeRow("Benutzer", history.userName) }
            if !history.date.isEmpty { AttributeRow("Export", "\(history.date) \(history.time)") }
        }
    }
}

// MARK: - Rows

private struct LayerRow: View {
    @Bindable var model: AppModel
    let layer: BuildUpLayer
    let summary: LayerSummary
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        let visible = model.isVisible(layer)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: { model.toggle(layer) }) {
                    Image(systemName: visible ? "eye.fill" : "eye.slash")
                        .foregroundStyle(visible ? Color.accentColor : Color.secondary)
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(visible ? "Schicht \(layer.id) ausblenden" : "Schicht \(layer.id) einblenden")

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(layer.colour))
                    .frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.25)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(layer.id)
                        .font(.headline)
                        .monospaced()
                    Text(layer.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .opacity(visible ? 1 : 0.55)

            HStack(spacing: 12) {
                Metric("Bauteile", "\(summary.partCount)")
                Metric("Dicke", "\(Format.mm(layer.thickness)) mm")
                Metric("Gewicht", Format.kg(summary.totalWeight))
            }
            .padding(.leading, 32)

            if !summary.materials.isEmpty {
                Text(summary.materials.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
            }

            HStack(spacing: 8) {
                Button("Nur diese") { model.isolate(layer) }
                    .font(.caption)
                Text("Lage \(Format.mm(layer.normalRange.lowerBound)) … \(Format.mm(layer.normalRange.upperBound)) mm")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .padding(.leading, 32)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(layer) }
    }
}

private struct PartRow: View {
    let part: BTLxPart
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(part.singleMemberNumber)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(part.designation)
                        .font(.subheadline)
                    Text("\(part.crossSection) · \(Format.mm(part.length)) mm")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

private struct Metric: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
    }
}

struct AttributeRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
