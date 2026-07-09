import AVFoundation
import CoreAudio

/// Finding and selecting CoreAudio devices by name.
///
/// Phase 2 renders the converted voice into the "XVC Mic" virtual device instead of the
/// speakers. A virtual mic is an output like any other: whatever we render to its output
/// side appears at its input side, which is what Zoom reads (docs/MAC_APP.md §2).
enum AudioDevices {
    struct Device {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let inputChannels: Int
        let outputChannels: Int
    }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &dataSize) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &dataSize, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id,
                          name: name,
                          uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
                          inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                          outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput))
        }
    }

    /// Case-insensitive exact match, falling back to a unique prefix match.
    static func findOutput(named name: String) -> Device? {
        let outputs = all().filter { $0.outputChannels > 0 }
        if let exact = outputs.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        let prefix = outputs.filter { $0.name.lowercased().hasPrefix(name.lowercased()) }
        return prefix.count == 1 ? prefix[0] : nil
    }

    /// Point an AVAudioEngine's output at a specific device. Must be called before the
    /// engine starts — CoreAudio will not switch a running output unit.
    static func setOutputDevice(_ engine: AVAudioEngine, to device: Device) throws {
        guard let unit = engine.outputNode.audioUnit else {
            throw XVCError("output node has no audio unit")
        }
        var id = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw XVCError("could not select output device \"\(device.name)\" (OSStatus \(status))")
        }
    }

    // MARK: - property helpers

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value as String
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
