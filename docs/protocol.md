# USB protocol

What Earshot sends to the dongle and what comes back. Checked on an Arctis Nova 7P Gen 2, USB ID `1038:2298`. Most of it was first worked out by [HeadsetControl](https://github.com/Sapd/HeadsetControl) and [Arctis Sound Manager](https://github.com/loteran/Arctis-Sound-Manager), whose 7P Gen 2 profile was transcribed from SteelSeries GG's own device files.

## Transport

The dongle has a vendor HID interface on usage page `0xFFC0`. Every message is a 64-byte output report with report ID 0, padded with zeros, and the first byte is the opcode. Replies are input reports that start with the same opcode.

The dongle never sends anything unasked, so Earshot polls. A reply goes to every program that has the interface open, so another program's polls look like spontaneous reports when you are watching.

## Status: `b0`

| Byte | Meaning |
| --- | --- |
| 1 | Headset power: `03` on, `02` off |
| 2 | Battery, percent. Original 7P firmware `1038:220a` sends 0 to 4 |
| 3 | `01` charging, `02` on the cable and full, `03` on battery |
| 7 | Bluetooth: `00` on, `01` off |
| 8 | Game audio during Bluetooth calls: `00` unchanged, `01` 12 dB lower, `02` muted |
| 9 | Mic: `01` muted |

A headset that is off but on the charger reports `02` in byte 1, so charging it does not count as turning it on.

## Settings

The dongle answers these even with the headset off, which is how we know the headset stores its own settings.

| Query | Reply bytes |
| --- | --- |
| `20` | 1 mic volume `0`-`7`, 2 sidetone, which has no effect on the 7P, 3 volume limiter `0`/`1` |
| `a0` | 1 idle power-off in minutes, `0` is never, 2 mute light `0`-`3` |
| `a6 00` | 2 preset type, `00` built in or `01` custom, 3 onward the EQ preset name, NUL-terminated |
| `32 00` | The EQ curve: ten 6-byte bands from byte 2, in the band format below |

| Setting | Command |
| --- | --- |
| Mic volume | `37 <0-7>` |
| Volume limiter | `3a <0/1>` |
| Idle power-off | `a3 <minutes>`, one of 0, 1, 5, 10, 15, 30, 45, 60, 75, 90 |
| Mute light | `ae <0-3>` |
| Bluetooth | `b2 <0/1>` |
| Bluetooth calls | `b3 <0-2>` |
| Save | `09`, sent after each of the above |

## Equaliser

Three frames, and the headset changes nothing until the third:

1. `a7 00 <type> <name>`: type `00` built in or `01` custom, then the name in UTF-8.
2. `33 00 <10 bands>`: each band is frequency as 16-bit little-endian, filter `01` for peak, gain in tenths of a dB as a signed byte, and Q in thousandths as 16-bit little-endian.
3. `27`: apply.

The headset's own Flat preset is 32, 64, 125, 250, 500, 1000, 2000, 4000, 8000 and 16000 Hz, Q 1.414, 0 dB. Earshot's other presets use the same bands with HeadsetControl's gains.

HeadsetControl's older 10-byte `33` format, one byte per band, is for earlier models. The 7P Gen 2 ignores it.

## Verified

Every query above was answered by a 7P Gen 2. Writes were checked by reading back the result: mute light, and an EQ preset whose name and ten gains came back exactly. The other writes use the same path but have not each been checked. If you test one, please say so in an issue.
