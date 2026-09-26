# Python CLI (`scooter.py`)

A command-line client for macOS and Linux (any platform supported by
[bleak](https://github.com/hbldh/bleak)): lock, unlock, status and raw property access.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Get the encrypted BLE key into `secrets/scooter.env` — see
[getting-the-key.md](getting-the-key.md). A template is in
[`secrets/scooter.env.example`](../secrets/scooter.env.example):

```
SCOOTER_PSK_LOCAL=<encrypted BLE key, 64 hex chars>   # required
SCOOTER_BLE_ADDRESS=                                  # filled in automatically, see below
```

**Bluetooth permission (macOS):** the first run asks for Bluetooth access for your
terminal app (Terminal, iTerm, …). If it was denied: System Settings → Privacy & Security
→ Bluetooth → enable the terminal app.

## Before running

- The scooter is switched on.
- **No phone is connected to it.** The scooter accepts one BLE connection at a time —
  close the Mi Home app or switch off the phone's Bluetooth.

## Commands

The PIN is asked at runtime (not echoed, never stored).

```bash
.venv/bin/python scooter.py scan                 # nearby Xiaomi devices; the t2336 is marked (no PIN needed)
.venv/bin/python scooter.py status               # battery, SOH, lock state, range, odometer, temperature, firmware
.venv/bin/python scooter.py lock
.venv/bin/python scooter.py unlock
.venv/bin/python scooter.py get <siid> <piid>    # read one property, decoded (see docs/protocol.md)
.venv/bin/python scooter.py propsweep [s] [p]    # list all readable properties (default 16 × 24)
.venv/bin/python scooter.py monitor [seconds]    # live polling: W, A, V, km/h, battery, trip, °C, lock
.venv/bin/python scooter.py listen [seconds]     # passively print raw notifications
.venv/bin/python scooter.py set <siid> <piid> <value>   # write a one-byte value — use with care
```

The CLI output is in Hungarian (e.g. `ZÁRVA` = locked, `NYITVA` = unlocked).

## Finding the scooter

The first run scans for t2336 scooters by their MiBeacon product ID (`0x403D`), so other
Xiaomi devices nearby (scales, lamps, …) are ignored. If several identical scooters are
around, each one that rejects the key is skipped. After the first **successful** login the
scooter's address is written to `secrets/scooter.env` as `SCOOTER_BLE_ADDRESS` (on macOS a
CoreBluetooth UUID, on Linux the MAC address), and later runs connect only to it.

To search again (e.g. for another scooter), add `--rescan` to any command:

```bash
.venv/bin/python scooter.py status --rescan
```

## Debugging

`SCOOTER_DEBUG=1` prints the raw BLE frames.
