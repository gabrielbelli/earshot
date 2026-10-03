// Headset settings that GG would set, each read back from the headset. Commands, value ranges and
// read offsets are from Arctis Sound Manager (github.com/loteran/Arctis-Sound-Manager, GPL-3.0:
// devices/nova_7p_perc_battery.yaml and hardware_eq.py, transcribed from GG's device specs) and
// HeadsetControl. Every read query and two of the writes were checked on a Nova 7P Gen 2 (1038:2298).
//
//   b0 status   [7] Bluetooth (00 on, 01 off)  [8] Bluetooth call volume (0-2)  [9] mic muted
//   20 settings [1] mic volume (0-7)  [2] sidetone, no effect on the 7P  [3] volume limiter
//   a0 power    [1] idle power-off minutes (0 = never)  [2] mute light (0-3)
//   a6 00       [2] preset type (0 built-in, 1 custom)  [3...] EQ preset name, NUL-terminated
//
// A pick is sent once and saved (09); nothing is re-sent at power-on, so changes made in the phone
// app stay. The headset stores its settings: the dongle reports them with the headset off.

import Foundation

struct Control {
    let title: String
    let options: [(label: String, value: Int)]
    /// Reports to send, in order; each starts with the command byte.
    let commands: (Int) -> [[UInt8]]
    /// The current value, from the latest replies.
    let read: (Readings) -> Int?
}

private func byte(_ report: [UInt8], _ index: Int) -> Int? {
    report.count > index ? Int(report[index]) : nil
}

/// Sets one value, then saves (09), as GG's own init sequence does.
private func setting(_ opcode: UInt8) -> (Int) -> [[UInt8]] {
    { [[opcode, UInt8($0)], [0x09]] }
}

// MARK: - Equaliser

/// The headset's own Flat preset, read back with query 32: ten peaking bands at these frequencies,
/// Q 1.414, 0 dB.
private let bandFrequencies = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
let equaliserPresets: [(name: String, gains: [Double])] = [
    ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    // HeadsetControl's Nova 7 presets, as gains on the bands above.
    ("Bass boost", [3.5, 5.5, 4, 1, -1.5, -1.5, -1, -1, -1, -1]),
    ("Focus", [-5, -3.5, -1, -3.5, -2.5, 4, 6, -3.5, 0, 0]),
    ("Smiley", [3, 3.5, 1.5, -1.5, -4, -4, -2.5, 1.5, 3, 4]),
]

/// Three frames: name (a7), bands (33), apply (27). Each band is frequency (16-bit little-endian),
/// filter (01 peak), gain in tenths of a dB (signed byte) and Q in thousandths (16-bit). The 7P
/// changes nothing until the 27. Flat goes back as the built-in preset, the rest as custom.
private func equaliserFrames(_ index: Int) -> [[UInt8]] {
    let preset = equaliserPresets[index]
    let name = Array(preset.name.utf8.prefix(61))
    let bands = zip(bandFrequencies, preset.gains).flatMap { frequency, gain -> [UInt8] in
        let tenths = Int8(clamping: Int((gain * 10).rounded()))
        return [UInt8(frequency & 0xff), UInt8(frequency >> 8), 0x01, UInt8(bitPattern: tenths), 0x86, 0x05]
    }
    return [[0xa7, 0x00, index == 0 ? 0x00 : 0x01] + name, [0x33, 0x00] + bands, [0x27]]
}

// MARK: - The list

let controls: [Control] = [
    Control(title: "Microphone volume",
            options: [("Off", 0)] + (1...7).map { ("\($0)" + ($0 == 7 ? " (max)" : ""), $0) },
            commands: setting(0x37),
            read: { byte($0.settings, 1) }),
    Control(title: "Volume limiter",
            options: [("Off", 0), ("On", 1)],
            commands: setting(0x3a),
            read: { byte($0.settings, 3) }),
    Control(title: "Turn off when idle",
            options: [("Never", 0), ("After 1 minute", 1), ("After 5 minutes", 5), ("After 10 minutes", 10),
                      ("After 15 minutes", 15), ("After 30 minutes", 30), ("After 45 minutes", 45),
                      ("After 1 hour", 60), ("After 75 minutes", 75), ("After 90 minutes", 90)],
            commands: setting(0xa3),
            read: { byte($0.power, 1) }),
    Control(title: "Mute light brightness",
            options: [("Off", 0), ("Low", 1), ("Medium", 2), ("High", 3)],
            commands: setting(0xae),
            read: { byte($0.power, 2) }),
    Control(title: "Equaliser",
            options: equaliserPresets.indices.map { (equaliserPresets[$0].name, $0) },
            commands: equaliserFrames,
            read: { readings in readings.equaliserName.flatMap { name in equaliserPresets.firstIndex { $0.name == name } } }),
    Control(title: "Bluetooth",
            options: [("Off", 0), ("On", 1)],
            commands: setting(0xb2),
            read: { byte($0.status, 7).map { $0 == 0x00 ? 1 : 0 } }),
    Control(title: "Game audio during Bluetooth calls",
            options: [("Unchanged", 0), ("12 dB lower", 1), ("Muted", 2)],
            commands: setting(0xb3),
            read: { byte($0.status, 8) }),
]
