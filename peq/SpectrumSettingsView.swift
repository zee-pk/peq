import AppKit
import SwiftUI

struct SpectrumSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var draft = SpectrumAnalyzerSettings()
    @State private var profileName = ""

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Spectrum layout", selection: $draft.layoutMode) {
                    ForEach(SpectrumLayoutMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("Track Info + Spectrum shows Apple Music details above a spectrum occupying the lower 60% of the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Signal") {
                Picker("Spectrum audio", selection: $draft.audioSource) {
                    ForEach(SpectrumAudioSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                Text("Pre-EQ shows the incoming signal before equalization. Post-EQ shows the processed output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                DecimalSetting("Minimum level", value: $draft.minimumDb, range: SpectrumAnalyzerSettings.minimumDbRange, step: 1, suffix: "dB")
                DecimalSetting("Maximum level", value: $draft.maximumDb, range: SpectrumAnalyzerSettings.maximumDbRange, step: 1, suffix: "dB")
                Text("FFT size, hop, refresh interval, band count, and dB range rebuild the analyzer when applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Response") {
                DecimalSetting("Band fall", value: $draft.bandFallDbPerSecond, range: SpectrumAnalyzerTuning.fallRateRange, step: 1, suffix: "dB/s")
                DecimalSetting("Peak fall", value: $draft.peakFallDbPerSecond, range: SpectrumAnalyzerTuning.fallRateRange, step: 1, suffix: "dB/s")
                DecimalSetting("Peak hold", value: $draft.peakHoldSeconds, range: SpectrumAnalyzerSettings.peakHoldRange, step: 0.05, suffix: "s")
                DecimalSetting("Band separation", value: $draft.bandSeparation, range: SpectrumAnalyzerTuning.bandSeparationRange, step: 0.05, suffix: "amount")
            }

            Section("LED appearance") {
                HStack {
                    Menu("Load profile") {
                        if appState.spectrumLEDProfiles.isEmpty {
                            Text("No saved profiles")
                        } else {
                            ForEach(appState.spectrumLEDProfiles) { profile in
                                Button(profile.name) { profile.applying(to: &draft) }
                            }
                        }
                    }
                    Spacer()
                    Menu("Delete profile") {
                        if appState.spectrumLEDProfiles.isEmpty {
                            Text("No saved profiles")
                        } else {
                            ForEach(appState.spectrumLEDProfiles) { profile in
                                Button(profile.name, role: .destructive) { appState.deleteSpectrumLEDProfile(profile) }
                            }
                        }
                    }
                }
                HStack {
                    TextField("Profile name", text: $profileName)
                    Button("Save profile") {
                        appState.saveSpectrumLEDProfile(name: profileName, settings: draft)
                        profileName = ""
                    }
                    .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                IntegerSetting(
                    "Color regions",
                    value: regionCountBinding,
                    range: SpectrumAnalyzerSettings.ledRegionCountRange.lowerBound...maximumRegionCount,
                    suffix: "regions"
                )
                DecimalSetting("LED bars", value: ledRowCountBinding, range: SpectrumAnalyzerSettings.ledSegmentRange, step: 1, suffix: "bars")
                DecimalSetting("LED gap", value: $draft.ledGapPercent, range: SpectrumAnalyzerSettings.percentageRange, step: 1, suffix: "%")
                ForEach(Array(draft.ledRegions.enumerated()), id: \.element.id) { index, region in
                    ColorSetting("Region \(index + 1) color", rgb: colorBinding(for: region.id))
                    if index < draft.ledRegions.count - 1 {
                        IntegerSetting(
                            "Region \(index + 1) size",
                            value: rowCountBinding(for: region.id),
                            range: 1...maximumLEDRowCount,
                            suffix: "bars"
                        )
                    }
                }
                Text("Profiles contain LED appearance only. Each region has a fixed number of LED bars; the final region uses all remaining bars. Load a profile, then Apply to show it.")
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

    private var maximumLEDRowCount: Int { max(1, Int(draft.ledSegmentCount.rounded())) }
    private var maximumRegionCount: Int { min(SpectrumAnalyzerSettings.ledRegionCountRange.upperBound, maximumLEDRowCount) }

    private var regionCountBinding: Binding<Int> {
        Binding(get: { draft.ledRegions.count }, set: { draft.setLEDRegionCount($0) })
    }

    private var ledRowCountBinding: Binding<Double> {
        Binding(get: { draft.ledSegmentCount }, set: { draft.setLEDRowCount($0) })
    }

    private func rowCountBinding(for id: UUID) -> Binding<Int> {
        Binding(
            get: { draft.ledRegions.first(where: { $0.id == id })?.rowCount ?? 1 },
            set: { draft.setLEDRegionRowCount($0, id: id) }
        )
    }

    private func colorBinding(for id: UUID) -> Binding<Color> {
        Binding(
            get: {
                let rgb = draft.ledRegions.first(where: { $0.id == id })?.colorRGB ?? [0, 0, 0]
                return Color(red: rgb.indices.contains(0) ? rgb[0] : 0, green: rgb.indices.contains(1) ? rgb[1] : 0, blue: rgb.indices.contains(2) ? rgb[2] : 0)
            },
            set: { color in
                guard let nsColor = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                guard let index = draft.ledRegions.firstIndex(where: { $0.id == id }) else { return }
                draft.ledRegions[index].colorRGB = [Double(nsColor.redComponent), Double(nsColor.greenComponent), Double(nsColor.blueComponent)]
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
