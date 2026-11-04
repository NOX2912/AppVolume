import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String
    var description: String { "\(context) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, context: context()) }
}

/// Dünne Hilfsschicht über der C-API von Core Audio.
enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result), "Reading \(selector)")
        return result
    }

    static func getArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: T) throws -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "Size of \(selector)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var array = [T](repeating: element, count: count)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &array), "Reading \(selector)")
        return Array(array.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "Reading \(selector)")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    // MARK: Prozesse

    static func processObjects() -> [AudioObjectID] {
        (try? getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                       element: AudioObjectID(0))) ?? []
    }

    static func pid(of process: AudioObjectID) -> pid_t? {
        try? get(process, kAudioProcessPropertyPID, default: pid_t(-1))
    }

    static func bundleID(of process: AudioObjectID) -> String? {
        guard let id = try? getString(process, kAudioProcessPropertyBundleID), !id.isEmpty else { return nil }
        return id
    }

    static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        ((try? get(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0
    }

    // MARK: Geräte

    static func defaultOutputDevice() -> AudioDeviceID? {
        let id = try? get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                          default: AudioDeviceID(kAudioObjectUnknown))
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? {
        try? getString(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(_ object: AudioObjectID) -> String? {
        try? getString(object, kAudioObjectPropertyName)
    }

    static func streamCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        ((try? getArray(device, kAudioDevicePropertyStreams, scope: scope, element: AudioStreamID(0))) ?? []).count
    }
}

/// Merkt sich einen registrierten Property-Listener, damit er wieder entfernt werden kann.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector,
          queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        self.object = object
        self.address = CA.address(selector)
        self.queue = queue
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
