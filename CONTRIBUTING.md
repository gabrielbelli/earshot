# Contributing

Earshot is small on purpose. Help that keeps it small is the most welcome kind.

## Test your headset

This helps most, because I only own one model.

1. Install Earshot and turn the headset on.
2. Check the battery, then try a setting or two from the menu.
3. Open a [device report](https://github.com/gabrielbelli/earshot/issues/new?template=device-report.yml) with your model, its USB ID and Earshot's log:

```bash
log show --last 10m --predicate 'subsystem == "com.gabrielbelli.Earshot"'
```

Earshot only looks for the USB IDs in `productIDs`, in `Sources/Headset.swift`. To try another model, add its ID there and run `./build.sh`.

## Adding a headset

Any brand is welcome. Earshot is built around one headset today: the USB IDs and status report are in `Sources/Headset.swift`, the settings in `Sources/Controls.swift`. A second model is the right time to split those into one file per model, so open an issue first and we can agree on the shape.

Useful sources for a new headset: [HeadsetControl](https://github.com/Sapd/HeadsetControl) covers many brands, and a USB capture of the vendor's own app shows the rest.

## Bugs, ideas and opinions

Open an issue. Short is fine. "This confused me" is a useful report.

## Pull requests

- `./build.sh` must build with no warnings.
- One change per pull request.
- A new feature needs a reason someone would notice it. Removing things is welcome too.
- For anything about USB bytes, say where they came from, such as a capture, HeadsetControl or Arctis Sound Manager, and update [docs/protocol.md](docs/protocol.md).

By contributing you agree your work is released under the [BSD 2-Clause licence](LICENSE).
