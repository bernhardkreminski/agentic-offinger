# Agentic Offinger

iPad-App zur 3D-Visualisierung für die Arbeitsvorbereitung im Holzbau.
Liest BTLX-Dateien (design2machine, BTLX 2.x) und stellt das Element schichtweise dar.

## Funktionen

- **BTLX-Import** — über den Dateien-Picker (`.btlx`) oder die mitgelieferte Beispieldatei
  `RoWaPla Musterwand V3.btlx`, die beim Start automatisch geladen wird. Der UTType
  `com.design2machine.btlx` ist deklariert, die App erscheint daher auch in „Öffnen mit".
- **3D-Ansicht** — SceneKit, Orbit/Pan/Zoom, Standardansichten (Iso, Ansicht, Rückseite,
  Draufsicht, Seitlich), Kantendarstellung.
- **Schichten** — aus der Bauteillage entlang der Elementnormale abgeleitet:
  `RW` (Rahmenwerk), `BS1…` (Beplankung Seite 1 …), `IS1…` (Innenseite …).
  Mehrere Schichten gleichzeitig sichtbar, einzeln isolierbar, ausgeblendete Schichten
  optional als Geist, Schichten stufenlos auseinanderziehbar.
- **Bauteilinfo** — Antippen im 3D-Modell oder Auswahl in der Schichtliste zeigt alle
  Attribute: Produktionslisten-Nr., Bezeichnung, Material, Elementnummer, Baugruppe,
  Auftragsnummer, Geschoss, Stückzahl, Abmessungen, Gewicht, Lage/Achsen, Schwerpunkt,
  Bounding Box, GUID und sämtliche Bearbeitungen (JackRafterCut, Lap, …) mit Parametern.

## Technik

Ausschließlich Apple-Frameworks — SwiftUI, SceneKit, simd, Foundation `XMLParser`.
Keine Abhängigkeiten von Drittanbietern.

| Bereich | Datei |
| --- | --- |
| Datenmodell | `AgenticOffinger/Model/BTLxModel.swift` |
| BTLX-Parser | `AgenticOffinger/Model/BTLxParser.swift` |
| Schichtableitung | `AgenticOffinger/Model/LayerClassifier.swift` |
| Mesh-Aufbereitung | `AgenticOffinger/Scene/GeometryFactory.swift` |
| Szene | `AgenticOffinger/Scene/ModelScene.swift` |
| SceneKit-Ansicht | `AgenticOffinger/Scene/ModelSceneView.swift` |
| Oberfläche | `AgenticOffinger/UI/` |

BTLX ist millimeterbasiert und Z-oben, SceneKit metrisch und Y-oben. Beide Umrechnungen
sitzen auf einem einzigen Orientierungsknoten, damit die Bauteilknoten ihre originale
BTLX-Transformation behalten und direkt mit den Zahlen im Inspektor vergleichbar bleiben.

## Bauen

```
xcodebuild -project AgenticOffinger.xcodeproj -scheme AgenticOffinger \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

Ziel: iPadOS 18.0+, Xcode 26.
