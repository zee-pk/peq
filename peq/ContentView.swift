//
//  ContentView.swift
//  peq
//
//  Created by Muhammad Zeeshan on 01.05.2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingSavePreset = false
    @State private var newPresetName = ""
    @State private var draggedBandID: UUID?
    @State private var dropTargetBandID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(appState.savedPresets, id: \.self) { presetName in
                            Button(presetName) {
                                withAnimation {
                                    appState.loadPreset(name: presetName)
                                }
                            }
                        }
                        if !appState.savedPresets.isEmpty {
                            Divider()
                            Menu("Delete Preset") {
                                ForEach(appState.savedPresets, id: \.self) { presetName in
                                    Button(presetName) {
                                        appState.deletePreset(name: presetName)
                                    }
                                }
                            }
                            Divider()
                        }
                        Button("Save as Preset...") {
                            newPresetName = ""
                            showingSavePreset = true
                        }
                    } label: {
                        MaterialIconLabel(title: "Presets", icon: MaterialIconName.menu)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    
                    if let activePreset = appState.activePresetName {
                        HStack(spacing: 4) {
                            Text(activePreset)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            
                            if appState.isPresetModified {
                                Button {
                                    appState.savePreset(name: activePreset)
                                } label: {
                                    MaterialIcon(name: MaterialIconName.save)
                                        .help("Save changes to preset")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                Spacer()
                
                HStack(spacing: 16) {
                    Toggle("Bypass", isOn: Binding(
                        get: { appState.settings.bypass },
                        set: { appState.setBypass($0) }
                    ))
                    .toggleStyle(.switch)
                    
                    Toggle("Enable EQ", isOn: Binding(
                        get: { appState.isProcessing },
                        set: { appState.setProcessing($0) }
                    ))
                    .toggleStyle(.switch)
                    .tint(.accentColor)
                }
            }
            .padding()
            .background(Material.bar)
            
            Divider()
            
            // Status / Error Banner
            if appState.hasError {
                HStack(spacing: 10) {
                    MaterialIcon(name: MaterialIconName.warning, size: 20)
                        .foregroundStyle(.orange)
                    Text(appState.statusText)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("Retry") {
                        appState.setProcessing(true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.12))
                
                Divider()
            }

            ScrollView {
                VStack(spacing: 24) {
                    
                    // Output & Health Section
                    HStack(spacing: 20) {
                        // Output Gain Group
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                MaterialIconLabel(title: "Output Gain", icon: MaterialIconName.output)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Picker(
                                    "Device",
                                    selection: Binding(
                                        get: { appState.settings.targetOutputDeviceUID ?? "" },
                                        set: { appState.setTargetOutputDeviceUID($0.isEmpty ? nil : $0) }
                                    )
                                ) {
                                    Text("Select output device").tag("")
                                    ForEach(appState.outputDevices) { device in
                                        Text(device.name).tag(device.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity)

                                if appState.settings.targetOutputDeviceUID == nil {
                                    Text("Select the output device peq should follow.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if !appState.isConfiguredOutputDeviceActive {
                                    Text("EQ is bypassed until this device is the default output.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                HStack(spacing: 12) {
                                    Slider(
                                        value: Binding(
                                            get: { appState.settings.outputGainDb },
                                            set: { appState.setOutputGain($0) }
                                        ),
                                        in: EQLimits.outputGainDb,
                                        step: 0.5
                                    )
                                    
                                    HStack(spacing: 4) {
                                        NumberField(
                                            value: Binding(
                                                get: { appState.settings.outputGainDb },
                                                set: { appState.setOutputGain($0) }
                                            ),
                                            range: EQLimits.outputGainDb,
                                            step: 0.5,
                                            fractionDigits: 1,
                                            width: 60
                                        )
                                        Text("dB")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20, alignment: .leading)
                                    }
                                }
                                
                                Spacer()
                            }
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        
                        // Audio Health Group
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                MaterialIconLabel(title: "Audio Health", icon: MaterialIconName.health)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                
                                AudioHealthView(health: appState.audioHealth, isProcessing: appState.isProcessing)

                                HStack(spacing: 4) {
                                    Text("Media Keys")
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Text(appState.volumeHotkeyStatusText)
                                        .monospacedDigit()
                                        .foregroundStyle(.primary)
                                }
                                .font(.caption)
                                
                                Spacer()
                            }
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    // Bands Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Spacer()
                            
                            Button {
                                withAnimation {
                                    appState.addBand()
                                }
                            } label: {
                                MaterialIconLabel(title: "Add Band", icon: MaterialIconName.addCircle)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .font(.headline)
                        }
                        
                        VStack(spacing: 16) {
                            ForEach(Array(appState.settings.bands.enumerated()), id: \.element.id) { index, band in
                                GroupBox {
                                    BandRow(
                                        band: band,
                                        canRemove: appState.settings.bands.count > 1,
                                        canMoveUp: index > 0,
                                        canMoveDown: index < appState.settings.bands.count - 1,
                                        onChange: { appState.updateBand($0) },
                                        onMoveUp: {
                                            withAnimation {
                                                appState.moveBand(band, by: -1)
                                            }
                                        },
                                        onMoveDown: {
                                            withAnimation {
                                                appState.moveBand(band, by: 1)
                                            }
                                        },
                                        onRemove: { 
                                            withAnimation {
                                                appState.removeBand(band)
                                            }
                                        }
                                    )
                                    .padding(4)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.accentColor.opacity(dropTargetBandID == band.id ? 0.65 : 0), lineWidth: 2)
                                }
                                .onDrag {
                                    draggedBandID = band.id
                                    return NSItemProvider(object: band.id.uuidString as NSString)
                                }
                                .onDrop(
                                    of: [UTType.text],
                                    delegate: BandDropDelegate(
                                        targetBandID: band.id,
                                        draggedBandID: $draggedBandID,
                                        dropTargetBandID: $dropTargetBandID,
                                        onMove: { sourceID, targetID in
                                            withAnimation {
                                                appState.moveBand(withID: sourceID, before: targetID)
                                            }
                                        }
                                    )
                                )
                            }

                            BandDropTail(
                                isActive: draggedBandID != nil && dropTargetBandID == nil,
                                onDrop: {
                                    guard let draggedBandID else { return }
                                    withAnimation {
                                        appState.moveBand(withID: draggedBandID, before: nil)
                                    }
                                    self.draggedBandID = nil
                                    dropTargetBandID = nil
                                }
                            )
                            .onDrop(
                                of: [UTType.text],
                                delegate: BandTailDropDelegate(
                                    draggedBandID: $draggedBandID,
                                    dropTargetBandID: $dropTargetBandID,
                                    onMoveToEnd: { sourceID in
                                        withAnimation {
                                            appState.moveBand(withID: sourceID, before: nil)
                                        }
                                    }
                                )
                            )
                            .opacity(draggedBandID == nil ? 0 : 1)
                            .animation(.default, value: draggedBandID)
                        }
                        .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                            draggedBandID = nil
                            dropTargetBandID = nil
                            return false
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(NSColor.windowBackgroundColor))

            Divider()
            
            HStack {
                Button("Reset Defaults") {
                    withAnimation {
                        appState.resetDefaults()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding()
            .background(Material.bar)
        }
        .alert("Save Preset", isPresented: $showingSavePreset) {
            TextField("Preset Name", text: $newPresetName)
            Button("Save") {
                if !newPresetName.isEmpty {
                    appState.savePreset(name: newPresetName)
                }
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}

private struct AudioHealthView: View {
    let health: AudioHealthSnapshot
    let isProcessing: Bool

    var body: some View {
        Grid(horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                healthItem("Tap SR", sampleRateText(health.tapSampleRate))
                healthItem("Out SR", sampleRateText(health.outputSampleRate))
                healthItem("Fill", "\(health.bufferFillFrames)")
            }

            GridRow {
                healthItem("Pre", dbText(Float(health.effectivePreampDb)))
                healthItem("In Pk", peakText(health.capturedPeak))
                healthItem("Out Pk", peakText(health.outputPeak))
            }
        }
        .font(.caption)
        .foregroundStyle(isProcessing ? .secondary : .tertiary)
    }

    private func healthItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    private func sampleRateText(_ sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "-" }
        return String(format: "%.1f k", sampleRate / 1_000)
    }

    private func peakText(_ peak: Float) -> String {
        guard peak > 0 else { return "-inf" }
        let db = 20 * log10(Double(peak))
        return String(format: "%.1f dB", db)
    }

    private func dbText(_ value: Float) -> String {
        String(format: "%.1f dB", value)
    }
}

private struct BandRow: View {
    let band: EQBand
    let canRemove: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onChange: (EQBand) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Toggle(isOn: binding(\.enabled)) {
                    Text(band.name)
                        .font(.headline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                
                Spacer()

                HStack(spacing: 8) {
                    Button(action: onMoveUp) {
                        MaterialIcon(name: MaterialIconName.arrowUp)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveUp)
                    .foregroundStyle(canMoveUp ? Color.secondary : Color.gray)
                    .help("Move band up")

                    Button(action: onMoveDown) {
                        MaterialIcon(name: MaterialIconName.arrowDown)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveDown)
                    .foregroundStyle(canMoveDown ? Color.secondary : Color.gray)
                    .help("Move band down")
                }
                
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(!canRemove)
                .foregroundStyle(canRemove ? Color.red.opacity(0.8) : Color.gray)
            }

            Grid(horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    rowLabel("Freq")
                    Slider(value: binding(\.frequencyHz), in: EQLimits.frequencyHz)
                        .tint(.orange)
                    HStack(spacing: 4) {
                        NumberField(
                            value: binding(\.frequencyHz),
                            range: EQLimits.frequencyHz,
                            step: 1,
                            fractionDigits: 0,
                            width: 60
                        )
                        Text("Hz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .leading)
                    }
                }

                GridRow {
                    rowLabel("Gain")
                    Slider(value: binding(\.gainDb), in: EQLimits.bandGainDb, step: 0.5)
                        .tint(.blue)
                    HStack(spacing: 4) {
                        NumberField(
                            value: binding(\.gainDb),
                            range: EQLimits.bandGainDb,
                            step: 0.5,
                            fractionDigits: 1,
                            width: 60
                        )
                        Text("dB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .leading)
                    }
                }

                GridRow {
                    rowLabel("Q")
                    Slider(value: binding(\.bandwidth), in: EQLimits.bandwidth, step: 0.05)
                        .tint(.green)
                    HStack(spacing: 4) {
                        NumberField(
                            value: binding(\.bandwidth),
                            range: EQLimits.bandwidth,
                            step: 0.05,
                            fractionDigits: 2,
                            width: 60
                        )
                        Text("") // placeholder for alignment
                            .frame(width: 20, alignment: .leading)
                    }
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<EQBand, Value>) -> Binding<Value> {
        Binding(
            get: { band[keyPath: keyPath] },
            set: { value in
                var updated = band
                updated[keyPath: keyPath] = value
                onChange(updated)
            }
        )
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 32, alignment: .leading)
    }
}

private struct BandDropTail: View {
    let isActive: Bool
    let onDrop: () -> Void

    var body: some View {
        Button(action: onDrop) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(Color.accentColor.opacity(isActive ? 0.8 : 0.35))
                .frame(height: 36)
                .overlay {
                    Text("Drop here to move to end")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
    }
}

private struct BandDropDelegate: DropDelegate {
    let targetBandID: UUID
    @Binding var draggedBandID: UUID?
    @Binding var dropTargetBandID: UUID?
    let onMove: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard draggedBandID != targetBandID else { return }
        dropTargetBandID = targetBandID
    }

    func dropExited(info: DropInfo) {
        if dropTargetBandID == targetBandID {
            dropTargetBandID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedBandID = nil
            dropTargetBandID = nil
        }

        guard let draggedBandID, draggedBandID != targetBandID else { return false }
        onMove(draggedBandID, targetBandID)
        return true
    }
}

private struct BandTailDropDelegate: DropDelegate {
    @Binding var draggedBandID: UUID?
    @Binding var dropTargetBandID: UUID?
    let onMoveToEnd: (UUID) -> Void

    func dropEntered(info: DropInfo) {
        dropTargetBandID = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedBandID = nil
            dropTargetBandID = nil
        }

        guard let draggedBandID else { return false }
        onMoveToEnd(draggedBandID)
        return true
    }
}

private struct NumberField: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    let width: CGFloat

    func makeNSView(context: Context) -> ArrowKeyNumberTextField {
        let textField = ArrowKeyNumberTextField()
        textField.alignment = .right
        textField.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textField.bezelStyle = .roundedBezel
        textField.delegate = context.coordinator
        textField.formatter = nil
        textField.stringValue = formatted(value)
        return textField
    }

    func updateNSView(_ textField: ArrowKeyNumberTextField, context: Context) {
        context.coordinator.parent = self

        if !context.coordinator.isEditing {
            textField.stringValue = formatted(value)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ArrowKeyNumberTextField, context: Context) -> CGSize? {
        CGSize(width: width, height: 24)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.\(fractionDigits)f", value)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NumberField
        var isEditing = false

        init(parent: NumberField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isEditing = false
            guard let textField = notification.object as? NSTextField else { return }
            commit(textField.stringValue)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            commit(textField.stringValue)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                adjust(by: 1, textView: textView)
                return true
            }

            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                adjust(by: -1, textView: textView)
                return true
            }

            return false
        }

        private func adjust(by direction: Int, textView: NSTextView) {
            let nextValue = parent.value + (Double(direction) * parent.step)
            let adjustedValue = clamp(nextValue)
            parent.value = adjustedValue
            textView.string = formatted(adjustedValue)
        }

        private func commit(_ text: String) {
            guard let nextValue = Double(text) else { return }
            parent.value = clamp(nextValue)
        }

        private func clamp(_ value: Double) -> Double {
            min(max(value, parent.range.lowerBound), parent.range.upperBound)
        }

        private func formatted(_ value: Double) -> String {
            String(format: "%.\(parent.fractionDigits)f", value)
        }
    }
}

private final class ArrowKeyNumberTextField: NSTextField {}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
