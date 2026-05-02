import AudioToolbox
import CoreAudio
import Foundation

final class AudioTapManager {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private(set) var tapFormat = AudioStreamBasicDescription()

    var hasActiveTap: Bool {
        tapID != kAudioObjectUnknown && aggregateDeviceID != kAudioObjectUnknown
    }

    func start() throws -> AudioDeviceID {
        if hasActiveTap {
            return aggregateDeviceID
        }

        guard let excludedProcess = currentProcessObjectID() else {
            throw AudioRuntimeError.engine("Unable to exclude peq from the system audio tap")
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [excludedProcess])
        description.name = "peq System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior(rawValue: 2)!

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &createdTapID)
        guard status == noErr, createdTapID != kAudioObjectUnknown else {
            throw AudioRuntimeError.coreAudio("Unable to create Core Audio process tap", status)
        }

        tapID = createdTapID
        tapFormat = try readTapFormat(createdTapID)

        let tapUID = try readTapUID(createdTapID)
        let aggregateUID = "com.arbisoft.peq.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "peq Private Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]

        var createdAggregateID = AudioDeviceID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregateID)
        guard status == noErr, createdAggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(createdTapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            tapFormat = AudioStreamBasicDescription()
            throw AudioRuntimeError.coreAudio("Unable to create private aggregate device for tap", status)
        }

        aggregateDeviceID = createdAggregateID
        return createdAggregateID
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        tapFormat = AudioStreamBasicDescription()
    }

    private func readTapUID(_ tapID: AudioObjectID) throws -> CFString {
        var tapUID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafeMutablePointer(to: &tapUID) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else {
            throw AudioRuntimeError.coreAudio("Unable to read process tap UID", status)
        }

        return tapUID
    }

    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw AudioRuntimeError.coreAudio("Unable to read process tap format", status)
        }

        return format
    }

    private func currentProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var processID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &size,
                &processID
            )
        }

        guard status == noErr, processID != kAudioObjectUnknown else {
            return nil
        }

        return processID
    }
}
