<p align="center">
  <img src="ios/ScooterLink/ScooterLink/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="ScooterLink icon">
</p>

<h1 align="center">ScooterLink</h1>

<p align="center">
  Lock, unlock and read your <b>Xiaomi Electric Scooter 4 Pro (2nd Gen)</b> directly over Bluetooth —<br>
  from an iPhone app, a home-screen widget, Control Center, or a Python CLI.
</p>

<p align="center">
  <img src="docs/images/app-light.png" width="240" alt="App, light mode">
  <img src="docs/images/app-dark.png" width="240" alt="App, dark mode">
</p>
<p align="center">
  <img src="docs/images/widget-light.png" width="280" alt="Widget">
</p>

The Xiaomi Electric Scooter 4 Pro (2nd Gen) (`xiaomi.scooter.t2336`) uses Xiaomi's
*securitychip* authentication and an encrypted MIoT SPEC channel — not the open `55 AA`
protocol of older M365 scooters. This project implements the full flow and documents it.
After a one-time key download from your Xiaomi account, everything runs locally: no Mi
Home app and no cloud round-trip.

## Features

- **Lock / unlock** in about 4 s (median, including connect and login)
- **Scooter data:** battery %, estimated range, current trip (distance and time), odometer,
  battery health (SOH), charge cycles, voltage, battery and controller temperature
- **iPhone app** (SwiftUI + CoreBluetooth) using the phone's own Bluetooth:
  - home-screen widget with lock/unlock buttons
  - controls for Control Center, the Lock Screen and the Action button
  - Shortcuts actions
  - Face ID required from the Lock Screen
  - optional cruise control on unlock (re-applied each ride, since the controller resets it)
- **Python CLI** for macOS and Linux: status, lock/unlock, any property, property sweep,
  live polling monitor
- **Your scooter only:** after the first successful login the scooter is remembered (in the
  app's settings / the CLI's config) — works even with several identical scooters nearby
- **Retries** with a fresh connection on a weak signal
- **Documented protocol:** login, transport, opcodes, property map and measured timing

## Supported device

Xiaomi Electric Scooter 4 Pro (2nd Gen), model `xiaomi.scooter.t2336`, MiBeacon product ID
`0x403D`. Other Xiaomi scooters with securitychip authentication are likely similar
(the Scooter 5 Pro uses the same family with different opcodes) but are not tested.

## Quick start

1. **Get the key** — fetch the scooter's encrypted BLE key from your Xiaomi account:
   [docs/getting-the-key.md](docs/getting-the-key.md)
2. Then use either
   - the **iPhone app**: [docs/ios-app.md](docs/ios-app.md), or
   - the **Python CLI**: [docs/python-cli.md](docs/python-cli.md)

How it works in one paragraph: the encrypted key plus your scooter PIN give the long-term
key (LTMK). An ECDH P-256 login with HKDF and an AES-CCM proof derives session keys. The
commands then travel AES-CCM-encrypted over a chunked MIoT SPEC transport (read `op=2`,
write `op=0`). Details: [docs/protocol.md](docs/protocol.md).

## Repository layout

```
├── LICENSE                    MIT
├── scooter.py                 Python CLI (lock, unlock, status, properties, monitor)
├── requirements.txt           Python dependencies (CLI and key download)
├── secrets/
│   └── scooter.env.example    template for the (git-ignored) local key file
├── tokens/
│   ├── get_ltmk.py            fetches the scooter's encrypted BLE key from the Xiaomi cloud
│   ├── token_extractor.py     Xiaomi cloud login (vendored, MIT — see tokens/LICENSE)
│   └── LICENSE
├── ios/
│   ├── ScooterLink/           iPhone app, widget extension, shared code (XcodeGen project)
│   └── verify/                crypto/protocol test suite that runs without Xcode
└── docs/
    ├── getting-the-key.md
    ├── python-cli.md
    ├── ios-app.md
    ├── protocol.md
    └── images/
```

## Tests

```bash
bash ios/verify/run.sh        # crypto and protocol vs. reference vectors, retry rules, frame queue
```

The iPhone app also has on-device self-tests and a handshake benchmark that run against a
real scooter without changing its state — see [docs/ios-app.md](docs/ios-app.md#testing-and-diagnostics).

## Credits

- [KuziaMother/SCOOTER_5_PRO](https://github.com/KuziaMother/SCOOTER_5_PRO) — Scooter 5 Pro
  client (same protocol family). The `askbluetoothkey` cloud endpoint was first shown here.
- [desperado0044/xiaomi-scooter-link](https://github.com/desperado0044/xiaomi-scooter-link) —
  Android client. The t2336 property names, types and scaling come from here.
- [PiotrMachowski/Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) —
  Xiaomi cloud login, vendored in `tokens/` under its MIT license.
- [dnandha/miauth](https://github.com/dnandha/miauth) — Xiaomi BLE authentication reference.
- *E-Spoofer* (ACM WiSec 2023) — academic analysis of Xiaomi scooter BLE authentication.

## License

[MIT](LICENSE). `tokens/token_extractor.py` is © Piotr Machowski, MIT-licensed — see
[tokens/LICENSE](tokens/LICENSE).

## Disclaimer

This is an independent project, not affiliated with or endorsed by Xiaomi. Use it only
with a scooter you own, at your own risk. Do not lock or unlock while riding. Keep your
key and PIN private: together they allow anyone in Bluetooth range to control the scooter.
