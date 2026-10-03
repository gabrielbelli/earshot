// Default-device switching: makes the headset the default output, alert and/or input device when it
// turns on, and switches each of those to the previous or a chosen device when it turns off.

import CoreAudio
import Foundation
import os

enum Role: String, CaseIterable {
    case output, alerts, input

    var title: String {
        switch self {
        case .output: "Sound output"
        case .alerts: "Sound effects (alerts)"
        case .input: "Microphone"
        }
    }

    var selector: AudioObjectPropertySelector {
        switch self {
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        case .alerts: kAudioHardwarePropertyDefaultSystemOutputDevice
        case .input: kAudioHardwarePropertyDefaultInputDevice
        }
    }

    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }
}

/// What to switch a role to when the headset turns off.
enum Fallback: Equatable {
    case none
    case previous
    case device(uid: String, name: String)

    var stored: String {
        switch self {
        case .none: "none"
        case .previous: "previous"
        case .device(let uid, let name): "device\t\(uid)\t\(name)"
        }
    }

    init(stored: String?) {
        let parts = stored?.components(separatedBy: "\t") ?? []
        switch parts.first {
        case "none": self = .none
        case "device" where parts.count == 3: self = .device(uid: parts[1], name: parts[2])
        default: self = .previous
        }
    }
}

struct AudioDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
}

// MARK: - CoreAudio helpers

enum Audio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func hasStreams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func allDevices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func devices(for role: Role) -> [AudioDevice] {
        allDevices().filter { hasStreams($0.id, role.scope) }
    }

    static func device(uid: String) -> AudioDevice? {
        allDevices().first { $0.uid == uid }
    }

    static func name(of id: AudioObjectID) -> String {
        string(id, kAudioObjectPropertyName) ?? "device \(id)"
    }

    /// The headset's own sound device, matched on its model UID ("<name>:<vendor>:<product>"),
    /// because the device UID carries the USB port and changes when the dongle moves.
    static func headset() -> AudioDevice? {
        let suffixes = productIDs.map { String(format: ":%04x:%04x", vendorID, $0) }
        return allDevices().first { device in
            let model = string(device.id, kAudioDevicePropertyModelUID)?.lowercased() ?? ""
            return suffixes.contains { model.hasSuffix($0) }
        }
    }

    static func defaultDevice(_ role: Role) -> AudioObjectID {
        var addr = address(role.selector)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        return id
    }

    static func setDefault(_ role: Role, _ id: AudioObjectID) {
        var addr = address(role.selector)
        var value = id
        let err = AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        log(err == noErr ? "\(role.title) -> \(name(of: id))" : "could not set \(role.title) to \(name(of: id)): \(err)")
    }
}

private let logger = Logger(subsystem: "com.gabrielbelli.Earshot", category: "earshot")

/// State changes, switches and sent commands. Read them with
/// `log show --last 1h --predicate 'subsystem == "com.gabrielbelli.Earshot"'`.
func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
}

// MARK: - Settings

enum Settings {
    static let store = UserDefaults.standard

    static func registerDefaults() {
        store.register(defaults: [
            "useHeadset.output": true,
            "useHeadset.alerts": true,
            "useHeadset.input": true,
        ])
    }

    static func useHeadset(_ role: Role) -> Bool { store.bool(forKey: "useHeadset.\(role.rawValue)") }
    static func setUseHeadset(_ role: Role, _ on: Bool) { store.set(on, forKey: "useHeadset.\(role.rawValue)") }

    static func fallback(_ role: Role) -> Fallback { Fallback(stored: store.string(forKey: "fallback.\(role.rawValue)")) }
    static func setFallback(_ role: Role, _ fallback: Fallback) { store.set(fallback.stored, forKey: "fallback.\(role.rawValue)") }

    /// UID of the device that was in use just before the headset took the role.
    static func previous(_ role: Role) -> String? { store.string(forKey: "previous.\(role.rawValue)") }
    static func setPrevious(_ role: Role, _ uid: String) { store.set(uid, forKey: "previous.\(role.rawValue)") }
}

// MARK: - Switcher

final class Switcher {
    private var lastDefault: [Role: AudioObjectID] = [:]
    /// Headset turned on before its sound device appeared (dongle just plugged in).
    private var connectPending = false

    init() {
        for role in Role.allCases {
            lastDefault[role] = Audio.defaultDevice(role)
            var addr = Audio.address(role.selector)
            AudioObjectAddPropertyListenerBlock(Audio.system, &addr, .main) { [weak self] _, _ in self?.defaultChanged(role) }
        }
        var devicesAddr = Audio.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(Audio.system, &devicesAddr, .main) { [weak self] _, _ in
            guard let self, self.connectPending, Audio.headset() != nil else { return }
            self.headsetOn()
        }
    }

    /// Remembers what was in use before the headset took a role, whoever made the switch.
    private func defaultChanged(_ role: Role) {
        let new = Audio.defaultDevice(role)
        let old = lastDefault[role]
        lastDefault[role] = new
        guard let headset = Audio.headset(), new == headset.id, let old, old != headset.id,
              let uid = Audio.string(old, kAudioDevicePropertyDeviceUID) else { return }
        Settings.setPrevious(role, uid)
    }

    func headsetOn() {
        guard let headset = Audio.headset() else { connectPending = true; return }
        connectPending = false
        for role in Role.allCases where Settings.useHeadset(role) && Audio.defaultDevice(role) != headset.id {
            Audio.setDefault(role, headset.id)
        }
    }

    func headsetOff() {
        connectPending = false
        let headset = Audio.headset()  // nil once the dongle is unplugged
        for role in Role.allCases {
            // With the dongle still in, leave a role alone if it was already moved off the headset.
            if let headset, Audio.defaultDevice(role) != headset.id { continue }
            guard let target = target(for: role), target != headset?.id else { continue }
            Audio.setDefault(role, target)
        }
    }

    private func target(for role: Role) -> AudioObjectID? {
        let previous = Settings.previous(role).flatMap(Audio.device(uid:))?.id
        switch Settings.fallback(role) {
        case .none: return nil
        case .previous: return previous
        case .device(let uid, _): return Audio.device(uid: uid)?.id ?? previous
        }
    }

    func previousName(_ role: Role) -> String? {
        Settings.previous(role).flatMap(Audio.device(uid:))?.name
    }
}
