# The t2336 Bluetooth protocol

This document describes how the **Xiaomi Electric Scooter 4 Pro (2nd Gen)**
(`xiaomi.scooter.t2336`) is authenticated and controlled over Bluetooth LE, as implemented
by `scooter.py` (Python) and the iOS app (`ScooterBLE.swift`, `ScooterProtocol.swift`,
`ScooterCrypto.swift`).

The scooter does **not** use the open `55 AA` / Nordic UART protocol of older M365
scooters. It uses Xiaomi's *securitychip* authentication followed by an encrypted
MIoT SPEC channel.

## Device

| | |
| --- | --- |
| Model | `xiaomi.scooter.t2336` — spec `urn:miot-spec-v2:device:scooter:0000A077:xiaomi-t2336:1` |
| MiBeacon product ID | 16445 / `0x403D` (bytes 2–3, little-endian, of the `FE95` service data) |
| Advertised name | `dreame scooter` |
| GATT service | `0000FE95-0000-1000-8000-00805F9B34FB` (Xiaomi Inc.) |

Other Xiaomi devices (e.g. scales) advertise `FE95` too — always filter by product ID.

| Characteristic | Purpose |
| --- | --- |
| `0x0010` | control: A4 transport handshake, login start (`0x20`), login result (`0x21` OK / `0x22` rejected) |
| `0x0016` | login data channel: MNG frames and typed parcels (public key, proof) |
| `0x001A` / `0x001B` | encrypted MIoT SPEC channel (write / notify) |
| `0x001C` | MCU info (version, plaintext) |

> The scooter accepts **one** BLE connection at a time. While a phone (Mi Home app) is
> connected, it does not advertise and SPEC responses may not arrive.

## 1. The long-term key (LTMK)

The scooter's BLE key is fetched once from the Xiaomi cloud (`/share/askbluetoothkey`,
body `{"type":"own","did":"<did>","keyid":0}`). For the t2336 the answer has
`encrypt_type = 1`: the key is protected with the scooter **PIN**.

```
LTMK = AES-128-CBC-NoPadding-decrypt(
         key = MD5(PIN),
         IV  = 7aa4c68c590d4031b980d98b41023800,
         ct  = encrypted key from the cloud)          -> 32 bytes
```

The tools store only the encrypted key; the PIN is supplied at runtime. How to fetch the
key: [getting-the-key.md](getting-the-key.md). The cloud may rotate the key — if login
starts failing with `0x22`, fetch it again.

## 2. Transport handshake (A4)

```
ctrl  (0x0010) <- A4
login (0x0016) -> 00 00 04 <idx> <maxPkg> <DMTU>     MNG
login (0x0016) <- 00 00 05 <idx> <maxPkg> <DMTU>     MNG_ACK
```

About 60 ms after the first MNG frame the scooter sends a second one (`00 00 04 01 …`);
it is ignored. **Timing matters:** the scooter does not accept the login start until
~400 ms after MNG_ACK (see [Timing](#6-timing)).

## 3. Login (securitychip ECDH)

```
1. ctrl (0x0010) <- 20 00 00 00                               login start
2. ephemeral P-256 key pair; our public key (64 B, X‖Y) -> type-3 parcel on 0x0016
3. receive the scooter's public key (type-3 parcel, 64 B)
4. shared  = ECDH-P256(scooter_pub, our_priv).X                (32 B)
   derived = HKDF-SHA256(ikm  = shared ‖ LTMK,
                         salt = "smartcfg-login-salt",
                         info = "smartcfg-login-info", length = 64)
   proof   = AES-CCM(key = derived[16:32], nonce = bytes 16..27, aad = ∅,
                     pt  = CRC32_LE(scooter_pub), tag = 4 B)
5. proof -> type-5 parcel on 0x0016
6. ctrl (0x0010) -> 21 = OK   /   22 = rejected (wrong PIN or outdated key)
```

Session keys from `derived`: `dev_key = [0:16]`, `app_key = [16:32]`,
`dev_iv = [32:36]`, `app_iv = [36:40]`.

**Typed parcels** on `0x0016`: header `00 00 00 <type> <count u16>`, the peer answers
`00 00 01 01` (ready), then frames `<seq u16> <≤18 bytes>`, and `00 00 01 00` (received).
Receiving works the same way in the other direction.

After a successful login the app reads the MCU info on `0x001C` (`00 00`, `01 00`) before
the first SPEC request.

## 4. Encrypted SPEC channel

```
nonce   = app_iv ‖ 00 00 00 00 ‖ counter (LE, 4 B)
payload = counter (LE, 2 B) ‖ AES-CCM(app_key, nonce, frame, tag = 4 B)
```

Responses are decrypted the same way with `dev_key` / `dev_iv` (the counter is taken from
the first two bytes of the response payload).

Transport on `0x001A` / `0x001B`:

```
-> CTR   00 00 00 00 <frameCount u16>
<- ACK   00 00 01 01                     ready
-> data  <seq u16> <chunk>  …            (seq from 1)
<- ACK   00 00 01 05 <missing seq …>     optional: resend request
<- CTR   00 00 00 00 <frameCount u16>    response header
-> ACK   00 00 01 01
<- data  <seq u16> <chunk>  …
-> ACK   00 00 01 00                     done
```

### MIoT SPEC frame

`[len | 0x2000 : u16][tid : u16][op : u8][count = 1 : u8]` followed by the body.

**The t2336 opcodes** (they differ from the Scooter 5 Pro reference):

| Operation | Request `op` | Response `op` | Body |
| --- | --- | --- | --- |
| Read (GET) | **2** | 3 | `[siid u8, piid u16]` (no value) |
| Write (SET) | **0** | 1 | `[siid u8, piid u16, type/length u16, value…]` |

The response body is `[siid, piid, status u16, (GET) type/length u16, value]`;
`status = 0` means OK. Lock = SET `(2,2)` to `01`, unlock = SET `(2,2)` to `00`.

## 5. Property map

Names, types and scaling follow [desperado0044/xiaomi-scooter-link](https://github.com/desperado0044/xiaomi-scooter-link)
(verified on a t2336) and match our own readings. **All FLOAT values are sent ×100 →
scale 0.01.**

**siid 1 — drive / battery**

| piid | name | type | unit |
| --- | --- | --- | --- |
| 1 | RIDING_MODE | u8 | |
| 2 | BATTERY_LEVEL | u8 | % |
| 3 | REMAINING_BATTERY | u16 | mAh |
| 4 | VOLTAGE | float ×0.01 | V |
| 5 | CURRENT | float ×0.01 | A |
| 6 | POWER | float ×0.01 | W |
| 7 | REMAINING_MILEAGE | float ×0.01 | km (estimated range) |
| 8 | FAULT | u8 | error code |
| 9 | CURRENT_MILEAGE | float ×0.01 | km (current trip) |

**siid 2 — speed / settings**

| piid | name | type | unit |
| --- | --- | --- | --- |
| 1 | AVERAGE_SPEED | float ×0.01 | km/h |
| 2 | IS_LOCKED | bool | 1 = locked (writable) |
| 3 | CRUISE_IS_ON | bool | |
| 4 | TAIL_LIGHT_IS_ON | bool | |
| 5 | ENERGY_RECOVERY | u8 | regeneration level |
| 6 | TOTAL_MILEAGE | float ×0.01 | km (odometer) |
| 7 | IS_RIDING | u8 | |
| 8 | RIDING_TIME | float | s (current trip) |
| 9 | HIGHEST_SPEED | float ×0.01 | km/h |
| 10 | ASR_IS_ON | bool | |
| 11 | REMAINING_MILEAGE_ALGORITHM | u8 | |
| 12 | AUTO_LIGHT | bool | |
| 13 | TCS | bool | |
| 14 | INTELLIGENT_DOWNHILL | bool | |
| 15 | HILL_PARKING | bool | |
| 16 | ATMOSPHERE_LIGHT | u8 | |
| 17 | BLUETOOTH_SEARCH_ON | bool | |
| 18 | FAKE_SHUTDOWN_STATUS | bool | |

**siid 3 — battery health / maintenance**

| piid | name | type | unit |
| --- | --- | --- | --- |
| 1 | BATTERY_STATUS | u8 | |
| 2 | BATTERY_TEMPERATURE | i8 | °C |
| 3 | SCOOTER_TEMPERATURE | i8 | °C (controller) |
| 4 | LOCK_WARNING | u8 | |
| 5 | MILEAGE_UNIT | u8 | 1 = km, 0 = mi |
| 7 | TIRE_MAINTENANCE | str | |
| 8 | ACTIVATION_DATE | str | |
| 10 | IS_CHARGING | bool | |
| 11 | NUMBER_OF_CYCLES | u8 | charge cycles |
| 12 | SOH | u8 | % (battery state of health) |

**siid 4 — device info (strings):** 1 PRODUCTION_DATE, 2 BATTERY_SN,
3 BMS_FIRMWARE_VERSION, 4 SCOOTER_SN, 5 FIRMWARE_VERSION, 7–8 MORE_BATTERY_INFO (hex).

**siid 6 — ride log:** `LOG_1…LOG_5` (packed ride records).

Notes:
- There is **no instantaneous speed** property — only AVERAGE_SPEED and HIGHEST_SPEED.
  `POWER` / `CURRENT` / `VOLTAGE` change in real time while riding.
- The scooter does not push telemetry by itself; values are polled.
- `(4,10)` BLUETOOTH_CAR_SEARCH is write-only (the scooter beeps/flashes). `(3,6)`
  OOB_CODE (pairing secret) and `(4,6)` RESTORE_SETTINGS (factory reset) are sensitive —
  do not write them.

## 6. Timing

Measured on the phone against a real scooter (alternating configurations, no retries):

| Step | Finding | Used value |
| --- | --- | --- |
| MNG_ACK → login start | 200 ms: 0/6 · 400 ms: 5/6 · 500 ms: 8/8 · 600 ms: 30/30 · 800 ms: 22/22 | **600 ms** |
| discovery → A4 | the scooter answers A4 ~1.45 s after the connection, whenever A4 is sent | 400 ms |
| scan → connect | connecting directly to the known peripheral skips one advertising interval (median 1.0 s instead of 1.5–1.8 s) | direct, falls back to scanning after 4 s |

Result: a lock/unlock takes **~4.0 s** (median) including connect and login; 12/12
back-to-back operations succeeded. Waiting for "the traffic to settle" after A4
(~110 ms) failed 10/10 — the delay is the scooter's processing time, not frame traffic.
