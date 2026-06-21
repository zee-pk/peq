import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var isClipping = false
    @Published private(set) var statusText = "Stopped"
    @Published private(set) var hasError = false
    @Published private(set) var audioHealth = AudioHealthSnapshot.empty
    @Published var settings: EQSettings
    @Published private(set) var savedPresets: [String] = []
    @Published private(set) var activePresetName: String?
    @Published private(set) var isPresetModified = false
    @Published private(set) var outputDevices: [OutputDevice] = []
    @Published private(set) var currentOutputDeviceUID: String?
    @Published private(set) var isSavedTargetOutputDeviceMissing = false
    @Published private(set) var isVolumeHotkeyRemappingAvailable = false

    private let presetStore = PresetStore()
    private let deviceManager = DeviceManager()
    private let healthStore = AudioHealthStore()
    private lazy var levelMeter = AudioLevelMeter(healthStore: healthStore)
    private lazy var audioPipeline = AudioPipeline(levelMeter: levelMeter, healthStore: healthStore)
    private var levelTimer: Timer?
    private var isRebuildingAudioPath = false

    init() {
        self.settings = presetStore.load()
        self.savedPresets = presetStore.getSavedPresets()
        self.activePresetName = UserDefaults.standard.string(forKey: "peq.activePresetName")
        self.isPresetModified = UserDefaults.standard.bool(forKey: "peq.isPresetModified")
        refreshOutputDevices()
    }

    var isConfiguredOutputDeviceActive: Bool {
        guard !isSavedTargetOutputDeviceMissing,
              let targetUID = settings.targetOutputDeviceUID else { return false }
        return targetUID == currentOutputDeviceUID
    }

    var isEQEffective: Bool {
        isProcessing && !settings.bypass && isConfiguredOutputDeviceActive
    }

    var isOutputGainControlActive: Bool {
        isProcessing && !settings.bypass && isVolumeHotkeyRemappingAvailable
    }

    var selectedOutputDevicePickerItems: [OutputDevicePickerItem] {
        var items = outputDevices.map {
            OutputDevicePickerItem(id: $0.id, name: $0.name, isAvailable: true)
        }

        if let unavailableItem = unavailableSelectedOutputDevicePickerItem {
            items.append(unavailableItem)
        }

        return items
    }

    var unavailableSelectedOutputDevicePickerItem: OutputDevicePickerItem? {
        guard isSavedTargetOutputDeviceMissing, let targetUID = settings.targetOutputDeviceUID else {
            return nil
        }

        return OutputDevicePickerItem(
            id: targetUID,
            name: settings.targetOutputDeviceName ?? "Unavailable output device",
            isAvailable: false
        )
    }

    var outputDeviceSelectionCaption: String? {
        guard settings.targetOutputDeviceUID != nil else {
            return "Select the Target output device."
        }

        if isSavedTargetOutputDeviceMissing {
            return nil
        }

        if !isConfiguredOutputDeviceActive {
            return "EQ bands are bypassed until this device is the default output."
        }

        return nil
    }

    func refreshPresets() {
        savedPresets = presetStore.getSavedPresets()
    }

    func savePreset(name: String) {
        var presetToSave = settings
        presetToSave.bypass = false
        presetStore.savePreset(presetToSave, name: name)
        activePresetName = name
        isPresetModified = false
        UserDefaults.standard.set(name, forKey: "peq.activePresetName")
        UserDefaults.standard.set(false, forKey: "peq.isPresetModified")
        refreshPresets()
    }

    func loadPreset(name: String) {
        if let preset = presetStore.loadPreset(name: name) {
            let currentBypass = settings.bypass
            let currentTargetOutputDeviceUID = settings.targetOutputDeviceUID
            let currentTargetOutputDeviceName = settings.targetOutputDeviceName
            settings = preset
            settings.bypass = currentBypass // Do not load/change bypass
            settings.targetOutputDeviceUID = currentTargetOutputDeviceUID
            settings.targetOutputDeviceName = currentTargetOutputDeviceName
            activePresetName = name
            isPresetModified = false
            UserDefaults.standard.set(name, forKey: "peq.activePresetName")
            UserDefaults.standard.set(false, forKey: "peq.isPresetModified")
            persistAndRebuildIfNeeded()
        }
    }

    func deletePreset(name: String) {
        presetStore.deletePreset(name: name)
        if activePresetName == name {
            activePresetName = nil
            isPresetModified = false
            UserDefaults.standard.removeObject(forKey: "peq.activePresetName")
            UserDefaults.standard.set(false, forKey: "peq.isPresetModified")
        }
        refreshPresets()
    }


    func startMonitoring() {
        let shouldProcess = UserDefaults.standard.bool(forKey: "peq.isProcessing")
        
        deviceManager.start { [weak self] reason in
            DispatchQueue.main.async {
                self?.handleDeviceChange(reason: reason)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDeviceChange(reason: .wakeRecovery)
            }
        }

        if levelTimer == nil {
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let peak = self.levelMeter.currentPeak
                    self.audioHealth = self.audioPipeline.healthSnapshot()
                    self.isClipping = peak >= 1.0
                }
            }
        }
        
        if shouldProcess {
            setProcessing(true)
        }
    }

    func setProcessing(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "peq.isProcessing")
        if enabled {
            do {
                refreshOutputDevices()
                try audioPipeline.start(settings: effectiveSettings())
                isProcessing = true
                hasError = false
                updateStatusText()
            } catch {
                isProcessing = false
                hasError = true
                statusText = error.localizedDescription
            }
        } else {
            audioPipeline.stop()
            isProcessing = false
            isClipping = false
            hasError = false
            statusText = "Stopped"
        }
    }

    func setBypass(_ bypass: Bool) {
        settings.bypass = bypass
        persistAndApply()
    }

    func setTargetOutputDeviceUID(_ uid: String?) {
        guard settings.targetOutputDeviceUID != uid else { return }
        settings.targetOutputDeviceUID = uid
        settings.targetOutputDeviceName = outputDevices.first(where: { $0.id == uid })?.name
        markModified()
        refreshOutputDevices()
        persistAndApply()
    }

    func setOutputGain(_ gainDb: Double) {
        settings.outputGainDb = EQLimits.clamp(gainDb, to: EQLimits.outputGainDb)
        markModified()
        persistAndApply()
    }

    func adjustOutputGain(by deltaDb: Double) {
        setOutputGain(settings.outputGainDb + deltaDb)
    }

    func updateBand(_ band: EQBand) {
        guard let index = settings.bands.firstIndex(where: { $0.id == band.id }) else {
            return
        }

        var sanitizedBand = band
        sanitizedBand.frequencyHz = EQLimits.clamp(sanitizedBand.frequencyHz, to: EQLimits.frequencyHz)
        sanitizedBand.gainDb = EQLimits.clamp(sanitizedBand.gainDb, to: EQLimits.bandGainDb)
        sanitizedBand.bandwidth = EQLimits.clamp(sanitizedBand.bandwidth, to: EQLimits.bandwidth)
        settings.bands[index] = sanitizedBand
        markModified()
        persistAndApply()
    }

    func addBand() {
        settings.bands.append(EQSettings.newBand(number: settings.bands.count + 1))
        markModified()
        persistAndRebuildIfNeeded()
    }

    func removeBand(_ band: EQBand) {
        guard settings.bands.count > 1 else { return }
        settings.bands.removeAll { $0.id == band.id }
        renumberBands()
        markModified()
        persistAndRebuildIfNeeded()
    }

    func moveBand(_ band: EQBand, by offset: Int) {
        guard let currentIndex = settings.bands.firstIndex(where: { $0.id == band.id }) else { return }

        let nextIndex = currentIndex + offset
        guard settings.bands.indices.contains(nextIndex) else { return }

        settings.bands.swapAt(currentIndex, nextIndex)
        renumberBands()
        markModified()
        persistAndApply()
    }

    func moveBand(withID bandID: UUID, before targetBandID: UUID?) {
        guard let sourceIndex = settings.bands.firstIndex(where: { $0.id == bandID }) else { return }

        let destinationIndex: Int
        if let targetBandID {
            guard let targetIndex = settings.bands.firstIndex(where: { $0.id == targetBandID }) else { return }
            destinationIndex = targetIndex
        } else {
            destinationIndex = settings.bands.endIndex
        }

        let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        guard adjustedDestination != sourceIndex else { return }

        let movedBand = settings.bands.remove(at: sourceIndex)
        settings.bands.insert(movedBand, at: adjustedDestination)
        renumberBands()
        markModified()
        persistAndApply()
    }

    func resetDefaults() {
        let oldBypass = settings.bypass
        let oldTargetOutputDeviceUID = settings.targetOutputDeviceUID
        let oldTargetOutputDeviceName = settings.targetOutputDeviceName
        settings = .flat
        settings.bypass = oldBypass
        settings.targetOutputDeviceUID = oldTargetOutputDeviceUID
        settings.targetOutputDeviceName = oldTargetOutputDeviceName
        activePresetName = nil
        isPresetModified = false
        UserDefaults.standard.removeObject(forKey: "peq.activePresetName")
        UserDefaults.standard.set(false, forKey: "peq.isPresetModified")
        persistAndRebuildIfNeeded()
    }

    func setVolumeHotkeyRemappingAvailable(_ available: Bool) {
        isVolumeHotkeyRemappingAvailable = available
    }

    private func markModified() {
        if !isPresetModified && activePresetName != nil {
            isPresetModified = true
            UserDefaults.standard.set(true, forKey: "peq.isPresetModified")
        }
    }

    private func persistAndApply() {
        presetStore.save(settings)
        audioPipeline.apply(effectiveSettings())
        updateStatusText()
    }

    private func persistAndRebuildIfNeeded() {
        presetStore.save(settings)

        guard isProcessing else {
            audioPipeline.apply(effectiveSettings())
            updateStatusText()
            return
        }

        do {
            statusText = "Rebuilding audio path"
            try audioPipeline.start(settings: effectiveSettings())
            hasError = false
            updateStatusText()
        } catch {
            isProcessing = false
            hasError = true
            statusText = error.localizedDescription
        }
    }

    private func refreshOutputDevices() {
        outputDevices = deviceManager.outputDevices()
        currentOutputDeviceUID = try? deviceManager.defaultOutputDeviceUID()
        if let targetUID = settings.targetOutputDeviceUID {
            isSavedTargetOutputDeviceMissing = !outputDevices.contains { $0.id == targetUID }
        } else {
            isSavedTargetOutputDeviceMissing = false
        }
        syncPersistedTargetOutputDeviceName()
        updateStatusText()
    }

    private func effectiveSettings() -> EQSettings {
        var effective = settings
        effective.bypass = settings.bypass || !isConfiguredOutputDeviceActive
        return effective
    }

    private func updateStatusText() {
        guard !hasError else { return }

        if !isProcessing {
            statusText = "Stopped"
        } else if settings.targetOutputDeviceUID == nil {
            statusText = "Select an output device to enable EQ bands"
        } else if isSavedTargetOutputDeviceMissing {
            statusText = "Saved output device unavailable; EQ bands bypassed"
        } else if !isConfiguredOutputDeviceActive {
            statusText = "EQ bands bypassed until selected device is the default output"
        } else if settings.bypass {
            statusText = "EQ bypassed"
        } else {
            statusText = "EQ audio path enabled"
        }
    }

    private func syncPersistedTargetOutputDeviceName() {
        guard let uid = settings.targetOutputDeviceUID else {
            if settings.targetOutputDeviceName != nil {
                settings.targetOutputDeviceName = nil
                presetStore.save(settings)
            }
            return
        }

        guard let device = outputDevices.first(where: { $0.id == uid }) else { return }
        guard settings.targetOutputDeviceName != device.name else { return }

        settings.targetOutputDeviceName = device.name
        presetStore.save(settings)
    }

    private func renumberBands() {
        for index in settings.bands.indices {
            settings.bands[index].name = "Band \(index + 1)"
        }
    }

    private func handleDeviceChange(reason: AudioDeviceChangeReason) {
        refreshOutputDevices()
        guard isProcessing, !isRebuildingAudioPath else { return }

        isRebuildingAudioPath = true
        statusText = "\(reason.statusText); rebuilding audio path"
        audioPipeline.scheduleRestart(reason: reason) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                self.isRebuildingAudioPath = false

                switch result {
                case .success:
                    self.isProcessing = true
                    self.hasError = false
                    self.refreshOutputDevices()
                    self.audioPipeline.apply(self.effectiveSettings())
                    self.updateStatusText()
                case .failure(let error):
                    self.isProcessing = false
                    self.hasError = true
                    self.statusText = error.localizedDescription
                }
            }
        }
    }
}

struct OutputDevicePickerItem: Identifiable, Equatable {
    let id: String
    let name: String
    let isAvailable: Bool
}
