import AppKit
import SwiftUI

struct SpectrumSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var draft = SpectrumAnalyzerSettings()

    var body: some View {
        Form {
            Section("Analysis") {
                Picker("FFT size", selection: $draft.fftSize) {
                    ForEach(SpectrumAnalyzerSettings.fftSizes, id: \.self) { size in
                        Text("\(size.formatted()) samples").tag(size)
                    }
                }
                IntegerSetting("Snapshot hop", value: $draft.snapshotHopFrames, range: SpectrumAnalyzerSettings.hopFrameRange, suffix: "frames")
                IntegerSetting("Refresh interval", value: $draft.refreshIntervalMilliseconds, range: SpectrumAnalyzerSettings.refreshIntervalRange, suffix: "ms")
                IntegerSetting("Bands", value: $draft.bandCount, range: SpectrumAnalyzerSettings.bandCountRange, suffix: "bands")
                DecimalSetting("Band gap", value: $draft.bandGapPixels, range: SpectrumAnalyzerSettings.bandGapRange, step: 1, suffix: "px")
                DecimalSetting("Peak hold", value: $draft.peakHoldSeconds, range: SpectrumAnalyzerSettings.peakHoldRange, step: 0.05, suffix: "s")
                Text("FFT size, hop, refresh interval, and band count rebuild the analyzer when applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Response") {
                DecimalSetting("Band fall", value: $draft.bandFallDbPerSecond, range: SpectrumAnalyzerTuning.fallRateRange, step: 1, suffix: "dB/s")
                DecimalSetting("Peak fall", value: $draft.peakFallDbPerSecond, range: SpectrumAnalyzerTuning.fallRateRange, step: 1, suffix: "dB/s")
                DecimalSetting("Band separation", value: $draft.bandSeparation, range: SpectrumAnalyzerTuning.bandSeparationRange, step: 0.05, suffix: "amount")
            }

            Section("LED appearance") {
                DecimalSetting("LED rows", value: $draft.ledSegmentCount, range: SpectrumAnalyzerSettings.ledSegmentRange, step: 1, suffix: "segments")
                DecimalSetting("LED gap", value: $draft.ledGapPercent, range: SpectrumAnalyzerSettings.percentageRange, step: 1, suffix: "%")
                ColorSetting("Dark red", rgb: colorBinding(\.darkRedRGB))
                DecimalSetting("Dark red region", value: $draft.darkRedRegionPercent, range: SpectrumAnalyzerSettings.percentageRange, step: 1, suffix: "%")
                ColorSetting("Orange red", rgb: colorBinding(\.orangeRedRGB))
                DecimalSetting("Orange red region", value: $draft.orangeRedRegionPercent, range: SpectrumAnalyzerSettings.percentageRange, step: 1, suffix: "%")
                ColorSetting("Orange", rgb: colorBinding(\.orangeRGB))
                DecimalSetting("Orange region", value: $draft.orangeRegionPercent, range: SpectrumAnalyzerSettings.percentageRange, step: 1, suffix: "%")
                ColorSetting("Yellow", rgb: colorBinding(\.yellowRGB))
                DecimalSetting("Yellow region", value: $draft.yellowRegionPercent, range: SpectrumAnalyzerSettings.percentageRange, step: 1, suffix: "%")
                Text("Color-region values are relative sizes and are automatically normalized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 680)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Reset") { draft = SpectrumAnalyzerSettings() }
                Spacer()
                Button("Apply") { appState.updateSpectrumSettings(draft) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(.bar)
        }
        .onAppear { draft = appState.spectrumSettings }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<SpectrumAnalyzerSettings, [Double]>) -> Binding<Color> {
        Binding(
            get: {
                let rgb = draft[keyPath: keyPath]
                return Color(red: rgb.indices.contains(0) ? rgb[0] : 0, green: rgb.indices.contains(1) ? rgb[1] : 0, blue: rgb.indices.contains(2) ? rgb[2] : 0)
            },
            set: { color in
                guard let nsColor = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                draft[keyPath: keyPath] = [Double(nsColor.redComponent), Double(nsColor.greenComponent), Double(nsColor.blueComponent)]
            }
        )
    }
}

private struct IntegerSetting: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String
    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) { self.title = title; _value = value; self.range = range; self.suffix = suffix }
    var body: some View { Stepper(value: $value, in: range) { LabeledContent(title) { Text("\(value) \(suffix)") } } }
}

private struct DecimalSetting: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String) { self.title = title; _value = value; self.range = range; self.step = step; self.suffix = suffix }
    var body: some View { Stepper(value: $value, in: range, step: step) { LabeledContent(title) { Text("\(value.formatted(.number.precision(.fractionLength(0...2)))) \(suffix)") } } }
}

private struct ColorSetting: View {
    let title: String
    @Binding var rgb: Color
    init(_ title: String, rgb: Binding<Color>) { self.title = title; _rgb = rgb }
    var body: some View { ColorPicker(title, selection: $rgb, supportsOpacity: false) }
}
