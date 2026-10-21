import AVFoundation
import CoreAudio
import Foundation

public struct MicDevice: Equatable, Identifiable, Sendable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    public var coreAudioID: AudioDeviceID

    public static let systemDefaultUID = ""
}

public enum MicDevices {
    /// Built-in / USB / aggregate input devices.
    public static func listInputs() -> [MicDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        var result: [MicDevice] = []
        for id in deviceIDs {
            guard inputChannelCount(id) > 0 else { continue }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "id-\(id)"
            let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
                ?? stringProperty(id, kAudioObjectPropertyName)
                ?? "Microphone \(id)"
            result.append(MicDevice(uid: uid, name: name, coreAudioID: id))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func defaultInput() -> MicDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? ""
        let name = stringProperty(deviceID, kAudioDevicePropertyDeviceNameCFString)
            ?? stringProperty(deviceID, kAudioObjectPropertyName)
            ?? "System default"
        return MicDevice(uid: uid, name: name, coreAudioID: deviceID)
    }

    public static func device(uid: String) -> MicDevice? {
        if uid.isEmpty { return defaultInput() }
        return listInputs().first { $0.uid == uid }
    }

    public static func displayName(forUID uid: String) -> String {
        if uid.isEmpty {
            if let def = defaultInput() { return "System default (\(def.name))" }
            return "System default"
        }
        return device(uid: uid)?.name ?? "Missing mic — using system default"
    }

    /// Point the system default input at this device so AVAudioRecorder uses it.
    @discardableResult
    public static func setDefaultInput(uid: String) -> Bool {
        guard !uid.isEmpty, let device = device(uid: uid) else { return true }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = device.coreAudioID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &deviceID
        )
        if status != noErr {
            NSLog("Vocalis: failed to set input device \(uid) (err \(status))")
            return false
        }
        return true
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else {
            return 0
        }
        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        var channels = 0
        for buffer in buffers {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return nil
        }
        var cfName: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfName else { return nil }
        return cfName as String
    }
}
