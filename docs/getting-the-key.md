# Getting the scooter key

To talk to the scooter you need two secrets:

| Secret | Where it comes from | Where it is stored |
| --- | --- | --- |
| **Encrypted BLE key** (64 hex characters) | your Xiaomi account, fetched once with `tokens/get_ltmk.py` | `secrets/scooter.env` (CLI) and the app's Keychain (iOS) |
| **Scooter PIN** | the PIN of your scooter in the Xiaomi Home / Mi Home app | typed at runtime (CLI) / Keychain (iOS) |

The key alone is useless without the PIN (it is AES-encrypted with `MD5(PIN)`), and both
stay on your own devices. `secrets/` is git-ignored.

## Prerequisites

- The scooter is added to your Xiaomi account (Xiaomi Home / Mi Home app).
- Python 3.10+ (tested with 3.13). On macOS: `brew install python@3.13`.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## 1. Find the scooter's device ID and region

```bash
.venv/bin/python tokens/token_extractor.py
```

Log in with your Xiaomi account (password or QR code; captcha and e-mail 2FA are
supported). The tool lists your devices per server region. Find the entry with
`MODEL: xiaomi.scooter.t2336` and note its **`ID`** (the device ID, a number) and the
**server** it was listed under (e.g. `de`, `us`, `cn`).

> The `BLE KEY` shown by this tool is a different key (the beacon key) — it is **not**
> the key needed here.

## 2. Fetch the encrypted BLE key

```bash
.venv/bin/python tokens/get_ltmk.py --did <ID> --server <region> --save
```

You log in again (the password is not echoed). With `--save` the key is written to
`secrets/scooter.env` as `SCOOTER_PSK_LOCAL`; other lines in the file are kept, and the
file is made readable only by you (mode `600`). Without `--save` the key is printed
instead.

For the iPhone app, copy the same 64-character value into **Settings › Felhőkulcs**
(cloud key) and enter the PIN in **Settings › Roller PIN**.

## When the key stops working

The cloud may rotate the BLE key. If the login is suddenly rejected (`0x22`, "login
rejected") although the PIN is right, run step 2 again and update the app's setting.

## How the key is used

```
LTMK = AES-128-CBC-NoPadding-decrypt(key = MD5(PIN), IV = 7aa4c68c590d4031b980d98b41023800,
                                     ciphertext = encrypted BLE key)
```

The LTMK feeds the ECDH login — see [protocol.md](protocol.md#3-login-securitychip-ecdh).
