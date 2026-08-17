import AppKit
import Combine
import Foundation

struct SpectrumPerformanceSnapshot: Equatable {
    static let zero = SpectrumPerformanceSnapshot(analyzerFPS: 0, deliveryFPS: 0, renderFPS: 0)

    let analyzerFPS: Double
    let deliveryFPS: Double
    let renderFPS: Double
}

private final class SpectrumPerformanceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var analyzerCompletions = 0
    private var mainDeliveries = 0

    func recordAnalyzerCompletion() {
        lock.lock()
        analyzerCompletions += 1
        lock.unlock()
    }

    func recordMainDelivery() {
        lock.lock()
        mainDeliveries += 1
        lock.unlock()
    }

    func sampleAndReset(elapsed: TimeInterval) -> (analyzerFPS: Double, deliveryFPS: Double) {
        lock.lock()
        let completions = analyzerCompletions
        let deliveries = mainDeliveries
        analyzerCompletions = 0
        mainDeliveries = 0
        lock.unlock()
        let safeElapsed = max(elapsed, 0.001)
        return (Double(completions) / safeElapsed, Double(deliveries) / safeElapsed)
    }

    func reset() {
        lock.lock()
        analyzerCompletions = 0
        mainDeliveries = 0
        lock.unlock()
    }
}

private final class LatestSpectrumDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingSnapshot: SpectrumSnapshot?
    private var isMainDeliveryQueued = false

    func submit(
        _ snapshot: SpectrumSnapshot,
        performanceCounter: SpectrumPerformanceCounter,
        deliver: @MainActor @escaping (SpectrumSnapshot) -> Void
    ) {
        performanceCounter.recordAnalyzerCompletion()
        lock.lock()
        pendingSnapshot = snapshot
        let shouldQueueDelivery = !isMainDeliveryQueued
        isMainDeliveryQueued = true
        lock.unlock()

        guard shouldQueueDelivery else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let latestSnapshot = self.pendingSnapshot
            self.pendingSnapshot = nil
            self.isMainDeliveryQueued = false
            self.lock.unlock()

            if let latestSnapshot {
                MainActor.assumeIsolated {
                    performanceCounter.recordMainDelivery()
                    deliver(latestSnapshot)
                }
            }
        }
    }
}

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
    @Published private(set) var spectrum = SpectrumSnapshot.empty
    @Published private(set) var spectrumPerformance = SpectrumPerformanceSnapshot.zero
    @Published private(set) var isSpectrumFullScreen = false
    @Published private(set) var spectrumSettings: SpectrumAnalyzerSettings

    private let presetStore = PresetStore()
    private let deviceManager = DeviceManager()
    private let healthStore = AudioHealthStore()
    private lazy var levelMeter = AudioLevelMeter(healthStore: healthStore)
    private var spectrumAnalyzer: AudioSpectrumAnalyzer
    private lazy var audioPipeline = AudioPipeline(levelMeter: levelMeter, spectrumAnalyzer: spectrumAnalyzer, healthStore: healthStore)
    private var levelTimer: Timer?
    private var isRebuildingAudioPath = false
    private var spectrumPresentationHandler: (() -> Void)?
    private var spectrumFullScreenHandler: (() -> Void)?
    private var spectrumSettingsPresentationHandler: (() -> Void)?
    private var isSpectrumPresented = false
    private let spectrumDelivery = LatestSpectrumDelivery()
    private let spectrumPerformanceCounter = SpectrumPerformanceCounter()
    private var spectrumPerformanceTimer: Timer?
    private var spectrumPerformanceSampleTime = CACurrentMediaTime()
    private var latestSpectrumRenderFPS = 0.0

    private static let spectrumSettingsKey = "peq.spectrumSettings"
    private static let legacySpectrumBandFallKey = "peq.spectrumBandFallDbPerSecond"
    private static let legacySpectrumPeakFallKey = "peq.spectrumPeakFallDbPerSecond"
    private static let legacySpectrumBandSeparationKey = "peq.spectrumBandSeparation"

    init() {
        self.settings = presetStore.load()
        self.savedPresets = presetStore.getSavedPresets()
        self.activePresetName = UserDefaults.standard.string(forKey: "peq.activePresetName")
        self.isPresetModified = UserDefaults.standard.bool(forKey: "peq.isPresetModified")
        let persistedSpectrumSettings = Self.persistedSpectrumSettings()
        self.spectrumSettings = persistedSpectrumSettings
        self.spectrumAnalyzer = AudioSpectrumAnalyzer(settings: persistedSpectrumSettings)
        refreshOutputDevices()
        configureSpectrumSnapshotDelivery()
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

    func setSpectrumPresentationHandler(_ handler: @escaping () -> Void) {
        spectrumPresentationHandler = handler
    }

    func setSpectrumSettingsPresentationHandler(_ handler: @escaping () -> Void) {
        spectrumSettingsPresentationHandler = handler
    }

    func setSpectrumFullScreenHandler(_ handler: @escaping () -> Void) {
        spectrumFullScreenHandler = handler
    }

    func setSpectrumPresented(_ presented: Bool) {
        isSpectrumPresented = presented
        spectrumAnalyzer.setEnabled(presented)
        if presented {
            startSpectrumPerformanceMeasurement()
        } else {
            stopSpectrumPerformanceMeasurement()
        }
        if !presented {
            isSpectrumFullScreen = false
        }
    }

    func setSpectrumFullScreen(_ fullScreen: Bool) {
        isSpectrumFullScreen = fullScreen
    }

    func setSpectrumBandFallDbPerSecond(_ value: Double) {
        spectrumSettings.bandFallDbPerSecond = Self.clampedFallRate(value)
        persistSpectrumSettings()
        spectrumAnalyzer.setDecayRates(
            bandFallDbPerSecond: spectrumSettings.bandFallDbPerSecond,
            peakFallDbPerSecond: spectrumSettings.peakFallDbPerSecond
        )
    }

    func setSpectrumPeakFallDbPerSecond(_ value: Double) {
        spectrumSettings.peakFallDbPerSecond = Self.clampedFallRate(value)
        persistSpectrumSettings()
        spectrumAnalyzer.setDecayRates(
            bandFallDbPerSecond: spectrumSettings.bandFallDbPerSecond,
            peakFallDbPerSecond: spectrumSettings.peakFallDbPerSecond
        )
    }

    func setSpectrumBandSeparation(_ value: Double) {
        spectrumSettings.bandSeparation = Self.clampedBandSeparation(value)
        persistSpectrumSettings()
        spectrumAnalyzer.setBandSeparation(spectrumSettings.bandSeparation)
    }

    func showSpectrumAnalyzer() {
        spectrumPresentationHandler?()
    }

    func showSpectrumSettings() { spectrumSettingsPresentationHandler?() }

    func updateSpectrumSettings(_ settings: SpectrumAnalyzerSettings) {
        var sanitized = settings
        sanitized.sanitize()
        let signalPathChanged = sanitized.fftSize != spectrumSettings.fftSize
            || sanitized.snapshotHopFrames != spectrumSettings.snapshotHopFrames
            || sanitized.refreshIntervalMilliseconds != spectrumSettings.refreshIntervalMilliseconds
            || sanitized.bandCount != spectrumSettings.bandCount
            || sanitized.minimumDb != spectrumSettings.minimumDb
            || sanitized.maximumDb != spectrumSettings.maximumDb
        spectrumSettings = sanitized
        persistSpectrumSettings()
        spectrumAnalyzer.setDecayRates(bandFallDbPerSecond: sanitized.bandFallDbPerSecond, peakFallDbPerSecond: sanitized.peakFallDbPerSecond)
        spectrumAnalyzer.setBandSeparation(sanitized.bandSeparation)
        spectrumAnalyzer.setPeakHoldSeconds(sanitized.peakHoldSeconds)
        if signalPathChanged { rebuildSpectrumAnalyzer() }
    }

    func toggleSpectrumFullScreen() {
        spectrumFullScreenHandler?()
    }

    func reportSpectrumRenderFPS(_ fps: Double) {
        latestSpectrumRenderFPS = fps
    }

    private func startSpectrumPerformanceMeasurement() {
        spectrumPerformanceTimer?.invalidate()
        spectrumPerformanceCounter.reset()
        spectrumPerformanceSampleTime = CACurrentMediaTime()
        latestSpectrumRenderFPS = 0
        spectrumPerformance = .zero
        spectrumPerformanceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleSpectrumPerformance()
            }
        }
        if let spectrumPerformanceTimer {
            RunLoop.main.add(spectrumPerformanceTimer, forMode: .common)
        }
    }

    private func stopSpectrumPerformanceMeasurement() {
        spectrumPerformanceTimer?.invalidate()
        spectrumPerformanceTimer = nil
        spectrumPerformanceCounter.reset()
        spectrumPerformance = .zero
    }

    private func sampleSpectrumPerformance() {
        let now = CACurrentMediaTime()
        let elapsed = now - spectrumPerformanceSampleTime
        spectrumPerformanceSampleTime = now
        let sample = spectrumPerformanceCounter.sampleAndReset(elapsed: elapsed)
        spectrumPerformance = SpectrumPerformanceSnapshot(
            analyzerFPS: sample.analyzerFPS,
            deliveryFPS: sample.deliveryFPS,
            renderFPS: latestSpectrumRenderFPS
        )
    }

    private func markModified() {
        if !isPresetModified && activePresetName != nil {
            isPresetModified = true
            UserDefaults.standard.set(true, forKey: "peq.isPresetModified")
        }
    }

    private static func persistedSpectrumSettings() -> SpectrumAnalyzerSettings {
        if let data = UserDefaults.standard.data(forKey: spectrumSettingsKey),
           var settings = try? JSONDecoder().decode(SpectrumAnalyzerSettings.self, from: data) {
            settings.sanitize()
            return settings
        }

        var settings = SpectrumAnalyzerSettings()
        let defaults = UserDefaults.standard
        if defaults.object(forKey: legacySpectrumBandFallKey) != nil {
            settings.bandFallDbPerSecond = defaults.double(forKey: legacySpectrumBandFallKey)
        }
        if defaults.object(forKey: legacySpectrumPeakFallKey) != nil {
            settings.peakFallDbPerSecond = defaults.double(forKey: legacySpectrumPeakFallKey)
        }
        if defaults.object(forKey: legacySpectrumBandSeparationKey) != nil {
            settings.bandSeparation = defaults.double(forKey: legacySpectrumBandSeparationKey)
        }
        settings.sanitize()
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: spectrumSettingsKey)
        }
        return settings
    }

    private static func clampedFallRate(_ value: Double) -> Double {
        min(max(value, SpectrumAnalyzerTuning.fallRateRange.lowerBound), SpectrumAnalyzerTuning.fallRateRange.upperBound)
    }

    private static func clampedBandSeparation(_ value: Double) -> Double {
        min(max(value, SpectrumAnalyzerTuning.bandSeparationRange.lowerBound), SpectrumAnalyzerTuning.bandSeparationRange.upperBound)
    }

    private func persistSpectrumSettings() {
        guard let data = try? JSONEncoder().encode(spectrumSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.spectrumSettingsKey)
    }

    private func configureSpectrumSnapshotDelivery() {
        spectrumAnalyzer.onSnapshot = { [weak self, spectrumDelivery] snapshot in
            guard let self else { return }
            spectrumDelivery.submit(snapshot, performanceCounter: self.spectrumPerformanceCounter) { @MainActor [weak self] latestSnapshot in
                self?.spectrum = latestSnapshot
            }
        }
    }

    private func rebuildSpectrumAnalyzer() {
        let wasProcessing = isProcessing
        if wasProcessing { audioPipeline.stop() }
        spectrumAnalyzer.setEnabled(false)
        spectrumAnalyzer = AudioSpectrumAnalyzer(settings: spectrumSettings)
        configureSpectrumSnapshotDelivery()
        spectrumAnalyzer.setEnabled(isSpectrumPresented)
        audioPipeline = AudioPipeline(levelMeter: levelMeter, spectrumAnalyzer: spectrumAnalyzer, healthStore: healthStore)
        guard wasProcessing else { return }
        do {
            try audioPipeline.start(settings: effectiveSettings())
            hasError = false
            updateStatusText()
        } catch {
            isProcessing = false
            hasError = true
            statusText = error.localizedDescription
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
