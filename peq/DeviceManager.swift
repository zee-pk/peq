import AudioToolbox
import CoreAudio
import Foundation

enum AudioDeviceChangeReason {
    case defaultOutputChanged
    case nominalSampleRateChanged
    case streamConfigurationChanged
    case streamFormatChanged
    case wakeRecovery

    var coalescingDelay: TimeInterval {
        switch self {
        case .defaultOutputChanged, .wakeRecovery:
            0.35
        case .nominalSampleRateChanged, .streamConfigurationChanged, .streamFormatChanged:
            0.2
        }
    }

    var statusText: String {
        switch self {
        case .defaultOutputChanged:
            "Default output changed"
        case .nominalSampleRateChanged:
            "Sample rate changed"
        case .streamConfigurationChanged:
            "Output stream changed"
        case .streamFormatChanged:
            "Output format changed"
        case .wakeRecovery:
            "Recovering after wake"
        }
    }
}

final class DeviceManager {
    private let callbackQueue = DispatchQueue(label: "com.arbisoft.peq.device-manager")
    private var callback: ((AudioDeviceChangeReason) -> Void)?
    private var isListening = false
    private var activeOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var systemListener: ListenerToken?
    private var deviceListeners: [ListenerToken] = []
    private var streamListeners: [ListenerToken] = []

    deinit {
        callbackQueue.sync {
            removeSystemListener()
            removeDeviceListeners()
            removeStreamListeners()
        }
    }

    func start(onChange: @escaping (AudioDeviceChangeReason) -> Void) {
        callbackQueue.async {
            self.callback = onChange

            guard !self.isListening else { return }
            self.isListening = true
            self.addDefaultOutputListener()
            self.rebuildOutputDeviceListeners()
        }
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioRuntimeError.coreAudio("Unable to read the default output device", status)
        }

        return deviceID
    }

    func defaultOutputDeviceUID() throws -> String {
        try deviceUID(for: defaultOutputDeviceID())
    }

    func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else {
            throw AudioRuntimeError.coreAudio("Unable to read the default output device UID", status)
        }

        return uid as String
    }

    private func addDefaultOutputListener() {
        guard systemListener == nil else { return }

        systemListener = addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        ) { [weak self] _, _ in
            self?.handleDefaultOutputDeviceChange()
        }
    }

    private func handleDefaultOutputDeviceChange() {
        rebuildOutputDeviceListeners()
        notifyChange(reason: .defaultOutputChanged)
    }

    private func handleOutputDevicePropertyChange(
        addressCount: UInt32,
        addresses: UnsafePointer<AudioObjectPropertyAddress>
    ) {
        if includesSelector(kAudioDevicePropertyStreams, addressCount: addressCount, addresses: addresses) {
            rebuildStreamFormatListeners()
            notifyChange(reason: .streamConfigurationChanged)
            return
        }

        if includesSelector(kAudioDevicePropertyNominalSampleRate, addressCount: addressCount, addresses: addresses) {
            notifyChange(reason: .nominalSampleRateChanged)
            return
        }

        notifyChange(reason: .streamConfigurationChanged)
    }

    private func handleStreamFormatChange() {
        notifyChange(reason: .streamFormatChanged)
    }

    private func rebuildOutputDeviceListeners() {
        removeDeviceListeners()
        removeStreamListeners()

        guard let deviceID = try? defaultOutputDeviceID() else {
            activeOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)
            return
        }

        activeOutputDeviceID = deviceID
        addOutputDeviceListeners(deviceID: deviceID)
        rebuildStreamFormatListeners()
    }

    private func addOutputDeviceListeners(deviceID: AudioDeviceID) {
        let properties: [(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput),
            (kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        ]

        for property in properties {
            if let listener = addListener(
                objectID: deviceID,
                selector: property.selector,
                scope: property.scope,
                onChange: { [weak self] addressCount, addresses in
                    self?.handleOutputDevicePropertyChange(addressCount: addressCount, addresses: addresses)
                }
            ) {
                deviceListeners.append(listener)
            }
        }
    }

    private func rebuildStreamFormatListeners() {
        removeStreamListeners()

        guard activeOutputDeviceID != kAudioObjectUnknown else { return }

        for streamID in outputStreamIDs(for: activeOutputDeviceID) {
            for selector in [kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat] {
                if let listener = addListener(
                    objectID: streamID,
                    selector: selector,
                    scope: kAudioObjectPropertyScopeGlobal,
                    onChange: { [weak self] _, _ in
                        self?.handleStreamFormatChange()
                    }
                ) {
                    streamListeners.append(listener)
                }
            }
        }
    }

    private func outputStreamIDs(for deviceID: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let streamCount = Int(dataSize) / MemoryLayout<AudioStreamID>.size
        guard streamCount > 0 else { return [] }

        var streamIDs = [AudioStreamID](repeating: AudioStreamID(kAudioObjectUnknown), count: streamCount)
        let status = streamIDs.withUnsafeMutableBufferPointer { pointer -> OSStatus in
            guard let baseAddress = pointer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, baseAddress)
        }

        guard status == noErr else { return [] }
        return streamIDs.filter { $0 != kAudioObjectUnknown }
    }

    private func addListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        onChange: @escaping AudioObjectPropertyListenerBlock
    ) -> ListenerToken? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, callbackQueue, onChange)
        guard status == noErr else { return nil }

        return ListenerToken(objectID: objectID, address: address, block: onChange)
    }

    private func removeSystemListener() {
        guard let systemListener else { return }
        remove(systemListener)
        self.systemListener = nil
    }

    private func removeDeviceListeners() {
        for listener in deviceListeners {
            remove(listener)
        }

        deviceListeners.removeAll()
    }

    private func removeStreamListeners() {
        for listener in streamListeners {
            remove(listener)
        }

        streamListeners.removeAll()
    }

    private func remove(_ token: ListenerToken) {
        var address = token.address
        AudioObjectRemovePropertyListenerBlock(token.objectID, &address, callbackQueue, token.block)
    }

    private func notifyChange(reason: AudioDeviceChangeReason) {
        callback?(reason)
    }

    private func includesSelector(
        _ selector: AudioObjectPropertySelector,
        addressCount: UInt32,
        addresses: UnsafePointer<AudioObjectPropertyAddress>
    ) -> Bool {
        for index in 0..<Int(addressCount) {
            if addresses[index].mSelector == selector {
                return true
            }
        }

        return false
    }
}

private struct ListenerToken {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}
