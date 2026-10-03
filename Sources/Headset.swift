// The headset, as seen through its USB dongle's vendor HID interface (usage page 0xFFC0).
//
// The dongle answers a b0 request with a status report: byte 1 headset power (03 on, 02 off),
// byte 2 battery percent (0-4 on the original 7P firmware), byte 3 charging (1 charging, 2 plugged
// in but not charging, 3 on battery), byte 9 mic muted. It never sends one unasked, so Earshot asks
// every second. Settings reports (20, a0, a6) are described in Controls.swift and docs/protocol.md.

import Foundation
import IOKit.hid

let vendorID = 0x1038
/// Arctis Nova 7P product IDs. 0x220a is the original firmware, which reports battery in five steps.
let productIDs = [0x2298, 0x22a7, 0x220a]
let discreteBatteryIDs: Set<Int> = [0x220a]
/// The dongle answers a request with the current state at once but does not report changes by
/// itself, so ask often. A request is one 64-byte USB report.
let pollInterval: TimeInterval = 1
/// Settings change rarely (from the phone app or this menu), so they are read every few polls.
let settingsEvery = 5
let lowBattery = 15

enum HeadsetState: Equatable {
    case noDongle
    case off
    case onBattery(Int)
    case charging(Int)
    /// On the cable but not charging, i.e. full.
    case pluggedIn(Int)
}

/// The latest reply to each read query, as received (byte 0 is the query's own opcode).
struct Readings {
    var status: [UInt8] = []     // b0
    var settings: [UInt8] = []   // 20: mic volume, sidetone, limiter
    var power: [UInt8] = []      // a0: idle power-off minutes, mute light
    var equaliserName: String?   // a6: name of the stored EQ preset
}

final class Headset {
    var onChange: (() -> Void)?
    private(set) var state = HeadsetState.noDongle
    /// The dongle's product string, e.g. "Arctis Nova 7P Gen 2".
    private(set) var name = "Headset"
    private(set) var micMuted = false
    private(set) var readings = Readings()
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private var productID = 0
    private var ticks = 0
    private var loggedSettings = ""
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    init() {
        let matching = productIDs.map {
            [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: $0, kIOHIDPrimaryUsagePageKey: 0xFFC0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<Headset>.fromOpaque(context!).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<Headset>.fromOpaque(context!).takeUnretainedValue().detach(device)
        }, context)
        // Common modes, so updates still arrive while the menu is open.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.request()
            self.ticks += 1
            if self.ticks % settingsEvery == 0 { self.requestSettings() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Asks for the status report; the answer arrives in `handle`.
    func request() {
        send([0xb0])
    }

    /// Asks for the three settings reports.
    func requestSettings() {
        send([0x20])
        send([0xa0])
        send([0xa6, 0x00])
    }

    /// Sends commands as 64-byte output reports (report ID 0), 50 ms apart (GG spaces them 30 ms),
    /// then reads the settings back so the menu shows what the headset now has.
    func send(commands: [[UInt8]]) {
        for (n, command) in commands.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(n)) { [weak self] in self?.send(command, log: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(commands.count) + 0.3) { [weak self] in
            self?.requestSettings()
        }
    }

    private func send(_ command: [UInt8], log logIt: Bool = false) {
        guard let device else { return }
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.replaceSubrange(0..<min(command.count, 64), with: command.prefix(64))
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bytes, bytes.count)
        if logIt || result != kIOReturnSuccess {
            log("sent " + command.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
                + (result == kIOReturnSuccess ? "" : String(format: " failed: 0x%x", result)))
        }
    }

    private func attach(_ device: IOHIDDevice) {
        self.device = device
        productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Headset"
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, { context, _, _, _, _, bytes, length in
            Unmanaged<Headset>.fromOpaque(context!).takeUnretainedValue().handle(bytes, length)
        }, Unmanaged.passUnretained(self).toOpaque())
        request()
        requestSettings()
    }

    private func detach(_ device: IOHIDDevice) {
        guard device == self.device else { return }
        self.device = nil
        readings = Readings()
        update(.noDongle)
    }

    private func handle(_ bytes: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        guard length >= 4 else { return }
        let report = Array(UnsafeBufferPointer(start: bytes, count: length))
        switch bytes[0] {
        case 0x20: readings.settings = report
        case 0xa0: readings.power = report
        case 0xa6:
            readings.equaliserName = String(decoding: report.dropFirst(3).prefix { $0 != 0 }, as: UTF8.self)
        case 0xb0:
            readings.status = report
            let raw = Int(bytes[2])
            let level = discreteBatteryIDs.contains(productID) ? min(raw, 4) * 25 : min(raw, 100)
            if bytes[1] != 0x03 {
                update(.off)
            } else {
                switch bytes[3] {
                case 0x01: update(.charging(level))
                case 0x02: update(.pluggedIn(level))
                default: update(.onBattery(level))
                }
            }
            let muted = length > 9 && bytes[1] == 0x03 && bytes[9] == 0x01
            if muted != micMuted {
                micMuted = muted
                log(muted ? "mic muted" : "mic unmuted")
                onChange?()
            }
        default: break
        }
        if [0x20, 0xa0, 0xa6].contains(bytes[0]) { logSettings() }
    }

    /// One log line with every setting, whenever one changes (phone app or this menu).
    private func logSettings() {
        let line = controls.map { control in
            let value = control.read(readings)
            let label = value.flatMap { v in control.options.first { $0.value == v }?.label }
            return "\(control.title)=\(label ?? value.map(String.init) ?? "?")"
        }.joined(separator: ", ") + ", EQ name=\(readings.equaliserName ?? "?")"
        guard line != loggedSettings else { return }
        loggedSettings = line
        log("settings: " + line)
    }

    /// Only a real change reaches the UI: redrawing the menu bar every poll cost 3% CPU.
    private func update(_ new: HeadsetState) {
        guard new != state else { return }
        log("headset \(new)")
        state = new
        onChange?()
    }

    var isOn: Bool {
        switch state {
        case .onBattery, .charging, .pluggedIn: true
        case .noDongle, .off: false
        }
    }
}

