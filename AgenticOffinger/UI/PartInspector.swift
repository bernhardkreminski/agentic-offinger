import SwiftUI

/// Everything the BTLX file says about the selected part: identification,
/// production-list data, nominal dimensions, placement and machining operations.
struct PartInspector: View {

    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let part = model.selectedPart, let document = model.document {
                content(part: part, document: document)
            } else {
                ContentUnavailableView("Kein Bauteil gewählt",
                                       systemImage: "hand.tap",
                                       description: Text("Bauteil im 3D-Modell antippen oder in der Schichtliste auswählen."))
            }
        }
    }

    private func content(part: BTLxPart, document: BTLxDocument) -> some View {
        List {
            Section {
                header(part: part, document: document)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section("Identifikation") {
                AttributeRow("Produktionslisten-Nr.", part.singleMemberNumber)
                AttributeRow("Bezeichnung", part.designation)
                AttributeRow("Material", part.material)
                AttributeRow("Elementnummer", part.elementNumber)
                AttributeRow("Baugruppe", part.assemblyNumber)
                AttributeRow("Auftragsnummer", part.orderNumber)
                AttributeRow("Geschoss", part.storey)
                AttributeRow("Stückzahl", "\(part.count)")
                AttributeRow("Schicht", "\(part.layerID) · \(layerName(part, document))")
            }

            Section("Abmessungen") {
                AttributeRow("Länge", "\(Format.mm(part.length)) mm")
                AttributeRow("Breite", "\(Format.mm(part.width)) mm")
                AttributeRow("Höhe", "\(Format.mm(part.height)) mm")
                AttributeRow("Querschnitt", part.crossSection)
                AttributeRow("Gewicht", Format.kg(part.weight))
                if part.count > 1 {
                    AttributeRow("Gewicht gesamt", Format.kg(part.weight * Double(part.count)))
                }
            }

            Section("Lage im Modell") {
                AttributeRow("Bezugspunkt", Format.point(part.origin))
                AttributeRow("X-Achse", Format.point(part.xAxis))
                AttributeRow("Y-Achse", Format.point(part.yAxis))
                AttributeRow("Z-Achse", Format.point(part.zAxis))
                if let cog = part.centerOfGravityWorld {
                    AttributeRow("Schwerpunkt", Format.point(cog))
                }
                AttributeRow("Bounding Box von", Format.point(part.worldBounds.min))
                AttributeRow("Bounding Box bis", Format.point(part.worldBounds.max))
                if let side = part.referenceSide {
                    AttributeRow("Bezugsseite", "Seite \(side)" + (part.referenceSideAlign.map { ", Align \($0)" } ?? ""))
                }
                if !part.guid.isEmpty {
                    AttributeRow("GUID", part.guid)
                }
            }

            Section("Geometrie") {
                AttributeRow("Eckpunkte", "\(part.mesh.points.count)")
                AttributeRow("Flächen", "\(part.mesh.faces.count)")
            }

            if part.processings.isEmpty {
                Section("Bearbeitungen") {
                    Text("Keine Bearbeitungen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Bearbeitungen (\(part.processings.count))") {
                    ForEach(part.processings) { processing in
                        ProcessingRow(processing: processing)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(part.designation)
    }

    private func header(part: BTLxPart, document: BTLxDocument) -> some View {
        let layer = document.layers.first { $0.id == part.layerID }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(layer?.colour ?? part.colour ?? SIMD4(0.7, 0.7, 0.7, 1)))
                    .frame(width: 34, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.2)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.designation)
                        .font(.title3.weight(.semibold))
                    Text("Pos. \(part.singleMemberNumber) · \(part.material)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Tag(text: part.layerID, colour: Color(layer?.colour ?? SIMD4(0.6, 0.6, 0.6, 1)))
                Tag(text: "\(Format.mm(part.length)) mm", colour: .secondary)
                Tag(text: part.crossSection, colour: .secondary)
                Tag(text: Format.kg(part.weight), colour: .secondary)
            }
        }
    }

    private func layerName(_ part: BTLxPart, _ document: BTLxDocument) -> String {
        document.layers.first { $0.id == part.layerID }?.name ?? "—"
    }
}

private struct Tag: View {
    let text: String
    let colour: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(colour.opacity(0.16), in: Capsule())
            .foregroundStyle(colour == .secondary ? Color.secondary : colour)
    }
}

private struct ProcessingRow: View {
    let processing: Processing
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(processing.name.isEmpty ? processing.displayName : processing.name)
                            .font(.subheadline.weight(.medium))
                        Text("\(processing.type) · ID \(processing.processID) · Bezugsebene \(processing.referencePlaneID)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !processing.isActive {
                        Text("inaktiv")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 2) {
                    if !processing.quality.isEmpty {
                        AttributeRow("Qualität", processing.quality)
                    }
                    ForEach(Array(processing.parameters.enumerated()), id: \.offset) { _, parameter in
                        AttributeRow(parameter.key, parameter.value)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 2)
    }
}
