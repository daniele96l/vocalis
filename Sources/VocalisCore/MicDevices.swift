import AVFoundation
import CoreAudio
import Foundation

public struct MicDevice: Equatable, Identifiable, Sendable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    public var coreAudioID: AudioDeviceID
    public var isBluetooth: Bool

    public static let systemDefaultUID = ""
}

public enum MicDevices {
    /// Built-in / USB / Bluetooth / aggregate input devices.
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
            result.append(
                MicDevice(
                    uid: uid,
                    name: name,
                    coreAudioID: id,
                    isBluetooth: isBluetoothTransport(id)
                )
            )
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func defaultInput() -> MicDevice? {
        guard let id = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice) else {
            return nil
        }
        let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
        let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
            ?? stringProperty(id, kAudioObjectPropertyName)
            ?? "System default"
        return MicDevice(uid: uid, name: name, coreAudioID: id, isBluetooth: isBluetoothTransport(id))
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
        guard let device = device(uid: uid) else {
            return "Missing mic — using system default"
        }
        return device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name
    }

    public static func nominalSampleRate(uid: String) -> Double {
        guard let device = device(uid: uid) else { return 48_000 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 48_000
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device.coreAudioID, &address, 0, nil, &size, &rate) == noErr else {
            return 48_000
        }
        return rate > 0 ? rate : 48_000
    }

    /// Activate the chosen input. For Bluetooth (AirPods), also route default *output*
    /// to the same device so macOS switches into headset/HFP mode — otherwise the
    /// mic often stays silent while A2DP playback is active.
    ///
    /// `routeChanged` is false when input (and BT output) were already correct — callers
    /// should skip settle delays in that case.
    @discardableResult
    public static func activateInput(uid: String) -> (ok: Bool, previousOutputUID: String?, routeChanged: Bool) {
        let target = device(uid: uid)
        guard let target else { return (true, nil, false) }

        var routeChanged = false
        if let currentIn = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice),
           currentIn != target.coreAudioID {
            routeChanged = true
        } else if defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice) == nil {
            routeChanged = true
        }

        let okIn = setDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice, id: target.coreAudioID)
        var previousOutUID: String?

        if target.isBluetooth {
            let currentOut = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
            if let currentOut {
                previousOutUID = stringProperty(currentOut, kAudioDevicePropertyDeviceUID)
            }
            // Prefer matching AirPods output endpoint if this UID is input-only.
            let outID = matchingOutputDeviceID(forInput: target) ?? target.coreAudioID
            if currentOut != outID {
                routeChanged = true
                _ = setDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice, id: outID)
            }
        }

        if !okIn {
            NSLog("Vocalis: failed to set input device \(target.uid)")
        }
        return (okIn, previousOutUID, routeChanged)
    }

    public static func restoreDefaultOutput(uid: String?) {
        guard let uid, !uid.isEmpty,
              let id = listAllDeviceIDs().first(where: {
                  stringProperty($0, kAudioDevicePropertyDeviceUID) == uid
              }) else { return }
        _ = setDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice, id: id)
    }

    @discardableResult
    public static func setDefaultInput(uid: String) -> Bool {
        activateInput(uid: uid).ok
    }

    /// True when the preferred (or system default) input is already Bluetooth HFP-ready
    /// (matching output also on that headset).
    public static func isBluetoothRouteWarm(uid: String) -> Bool {
        guard let target = device(uid: uid), target.isBluetooth else { return false }
        guard let currentIn = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice),
              currentIn == target.coreAudioID else { return false }
        let outID = matchingOutputDeviceID(forInput: target) ?? target.coreAudioID
        return defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice) == outID
    }

    // MARK: - Private

    private static func matchingOutputDeviceID(forInput device: MicDevice) -> AudioDeviceID? {
        // AirPods often expose separate input/output objects that share a name prefix.
        let base = device.name
            .replacingOccurrences(of: " Microphone", with: "")
            .replacingOccurrences(of: " Mic", with: "")
        for id in listAllDeviceIDs() {
            guard outputChannelCount(id) > 0 else { continue }
            let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
                ?? stringProperty(id, kAudioObjectPropertyName)
                ?? ""
            if name == device.name || name.hasPrefix(base) || base.hasPrefix(name) {
                return id
            }
        }
        return nil
    }

    private static func isBluetoothTransport(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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
        return deviceID
    }

    private static func setDefaultDevice(selector: AudioObjectPropertySelector, id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &deviceID
        ) == noErr
    }

    private static func listAllDeviceIDs() -> [AudioDeviceID] {
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
        return deviceIDs
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        channelCount(deviceID, scope: kAudioDevicePropertyScopeInput)
    }

    private static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        channelCount(deviceID, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
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
        var cfName: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfName else { return nil }
        return cfName as String
    }
}
