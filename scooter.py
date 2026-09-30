#!/usr/bin/env python3
"""Xiaomi Electric Scooter 4 Pro (2nd Gen) / t2336 — app nélküli vezérlés BLE-n.

A teljes securitychip protokoll (részletek: README.md):
  login:    ECDH-P256 + LTMK -> HKDF-SHA256 -> AES-CCM proof   (-> 0x21 OK)
  vezérlés: titkosított MIoT SPEC csatorna a 0x001a/0x001b-n

    ./scooter.py scan            # a közeli Xiaomi-eszközök, a t2336 megjelölve (PIN nem kell)
    ./scooter.py status --rescan # a rögzített roller helyett újrakeresés (és újra rögzítés)
    ./scooter.py status          # zár állapot + akku% (olvasás)
    ./scooter.py lock
    ./scooter.py unlock

A PIN-t getpass kéri (nem látszik). Az LTMK a secrets/scooter.env-ből
(SCOOTER_PSK_LOCAL = a felhő-kulcs), a PIN-nel dekódolva. A rollert a MiBeacon
product ID (0x403D) alapján maga keresi meg: ha több ugyanilyen is van a közelben, amelyik
elutasítja a kulcsot, azt kihagyja. Az első sikeres bejelentkezés után a címet a
secrets/scooter.env SCOOTER_BLE_ADDRESS sorába írja, és utána csak ahhoz csatlakozik.

t2336-specifikus SPEC opcode: OLVASÁS op=2 (válasz op=3), ÍRÁS op=0 (válasz op=1).
A 0x001b válasz csak egyetlen aktív BLE-kapcsolatnál jön — futtatás előtt a telefon
Bluetooth-át ki kell kapcsolni.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import os
import struct
import sys
import zlib
from getpass import getpass

from bleak import BleakClient
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESCCM
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

SVC = "0000fe95-0000-1000-8000-00805f9b34fb"
CONTROL = "00000010-0000-1000-8000-00805f9b34fb"
LOGINCH = "00000016-0000-1000-8000-00805f9b34fb"
SPEC_WRITE = "0000001a-0000-1000-8000-00805f9b34fb"
SPEC_NOTIFY = "0000001b-0000-1000-8000-00805f9b34fb"
MCU_INFO = "0000001c-0000-1000-8000-00805f9b34fb"

LOGIN_START = bytes.fromhex("20000000")
CFM_OK, CFM_FAIL = 0x21, 0x22
RCV_RDY = bytes.fromhex("00000101")
RCV_OK = bytes.fromhex("00000100")
SALT = b"smartcfg-login-salt"
INFO = b"smartcfg-login-info"
CCM_NONCE = bytes(range(16, 28))
LTMK_IV = bytes.fromhex("7aa4c68c590d4031b980d98b41023800")

# PacketType
CTR, ACK, MNG, MNG_ACK = 0x00, 0x01, 0x04, 0x05
A4 = 0xA4
SPEC_CHANNEL = 0
FRAME = 18  # login-hoz; SPEC-hez az A4-ben negociált DMTU-t használjuk

# A t2336 property-címei (propsweep-pel feltérképezve):
LOCK_SIID, LOCK_PIID = 2, 2    # IS_LOCKED (bool): 1=zárva, 0=nyitva (a többi property a PROPS-ban)

# A t2336 MIoT property-térképe. Forrás: desperado0044/xiaomi-scooter-link
# (SpecClient.kt + DashboardScreen.kt), a szerző élőben igazolta a t2336-on.
# A FLOAT telemetria a dróton value*100 -> a skálázás 0.01.
# (siid, piid): (NÉV, kind, scale, egység)   kind = u8/u16/i8/f/bool/str
PROPS = {
    (1, 1): ("RIDING_MODE", "u8", 1, ""),
    (1, 2): ("BATTERY_LEVEL", "u8", 1, "%"),
    (1, 3): ("REMAINING_BATTERY", "u16", 1, "mAh"),
    (1, 4): ("VOLTAGE", "f", 0.01, "V"),
    (1, 5): ("CURRENT", "f", 0.01, "A"),
    (1, 6): ("POWER", "f", 0.01, "W"),
    (1, 7): ("REMAINING_MILEAGE", "f", 0.01, "km"),
    (1, 8): ("FAULT", "u8", 1, ""),
    (1, 9): ("CURRENT_MILEAGE", "f", 0.01, "km"),
    (2, 1): ("AVERAGE_SPEED", "f", 0.01, "km/h"),
    (2, 2): ("IS_LOCKED", "bool", 1, ""),
    (2, 5): ("ENERGY_RECOVERY", "u8", 1, ""),
    (2, 6): ("TOTAL_MILEAGE", "f", 0.01, "km"),
    (2, 7): ("IS_RIDING", "u8", 1, ""),
    (2, 8): ("RIDING_TIME", "f", 60, "s"),   # a roller PERCben küldi -> x60 = másodperc
    (2, 9): ("HIGHEST_SPEED", "f", 0.01, "km/h"),
    (3, 2): ("BATTERY_TEMPERATURE", "i8", 1, "°C"),
    (3, 3): ("SCOOTER_TEMPERATURE", "i8", 1, "°C"),
    (3, 8): ("ACTIVATION_DATE", "str", 1, ""),
    (3, 11): ("NUMBER_OF_CYCLES", "u8", 1, ""),
    (3, 12): ("SOH", "u8", 1, "%"),
    (4, 2): ("BATTERY_SN", "str", 1, ""),
    (4, 4): ("SCOOTER_SN", "str", 1, ""),
    (4, 5): ("FIRMWARE_VERSION", "str", 1, ""),
}


SCOOTER_PID = 0x403D   # t2336 MiBeacon product ID
FE95 = "0000fe95-0000-1000-8000-00805f9b34fb"


def mibeacon_pid(adv):
    """A fe95 service data 2-3. bájtja a product ID (LE) — a fe95-öt más Xiaomi-eszköz is hirdeti."""
    sd = adv.service_data.get(FE95)
    return (sd[2] | (sd[3] << 8)) if sd and len(sd) >= 4 else None


async def find_scooters(timeout=15.0, collect=3.0):
    """A közeli t2336-ok (BLEDevice), legerősebb jel elöl: az első után még `collect` mp-ig gyűjt."""
    from bleak import BleakScanner
    seen = {}
    first = asyncio.get_running_loop().create_future()

    def cb(dev, adv):
        if mibeacon_pid(adv) == SCOOTER_PID:
            seen[dev.address] = (dev, adv.rssi)
            if not first.done():
                first.set_result(True)

    async with BleakScanner(cb):
        try:
            await asyncio.wait_for(first, timeout)
        except asyncio.TimeoutError:
            return []
        await asyncio.sleep(collect)
    return [d for d, _ in sorted(seen.values(), key=lambda x: -x[1])]


async def first_accepting(candidates, attempt):
    """Az első jelölt, amelyik elfogadja a kulcsot: (jelölt, attempt eredménye).
    A LoginRejected-et dobó (idegen) rollert kihagyja; ha mind elutasít, LoginRejected."""
    for c in candidates:
        try:
            return c, await attempt(c)
        except LoginRejected:
            print(f"  {getattr(c, 'address', c)}: elutasította a kulcsot — nem a tiéd? következő...")
    raise LoginRejected("a közeli roller(ek) mind elutasították a bejelentkezést (hibás PIN vagy kulcs?)")


def save_env_value(path, key, value):
    """KEY=value beírása / cseréje egy .env-fájlban (a többi sor érintetlen, jogosultság 600)."""
    lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
    out, done = [], False
    for line in lines:
        if line.split("=", 1)[0].strip() == key:
            out.append(f"{key}={value}")
            done = True
        else:
            out.append(line)
    if not done:
        out.append(f"{key}={value}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.chmod(path, 0o600)


async def scan(secs=8.0):
    """A közeli fe95-hirdetők listája product ID-vel; a t2336 megjelölve."""
    from bleak import BleakScanner
    seen = {}

    def cb(dev, adv):
        pid = mibeacon_pid(adv)
        if pid is not None:
            seen[dev.address] = (dev.name or adv.local_name or "?", pid, adv.rssi)

    print(f"Keresés {secs:.0f} mp-ig...")
    async with BleakScanner(cb):
        await asyncio.sleep(secs)
    if not seen:
        print("Nincs fe95-öt hirdető Xiaomi-eszköz a közelben.")
    for addr, (name, pid, rssi) in sorted(seen.items(), key=lambda x: -x[1][2]):
        mark = "  <- t2336 roller" if pid == SCOOTER_PID else ""
        print(f"  {addr}  {name:24} pid=0x{pid:04x}  rssi={rssi}{mark}")


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v.strip().strip('"')
    return env


class Keys:
    def __init__(self, derived: bytes):
        self.dev_key = derived[0:16]
        self.app_key = derived[16:32]
        self.dev_iv = derived[32:36]
        self.app_iv = derived[36:40]
        self.counter = int(os.environ.get("SCOOTER_CTR", "0"))  # SPEC kezdő számláló


class Bus:
    """CONTROL/LOGINCH külön sor; a két SPEC csatorna EGY közös, címkézett sorba
    megy, hogy ne kelljen két get()-et versenyeztetni (az keretet veszíthet)."""
    def __init__(self):
        self.q = {CONTROL: asyncio.Queue(), LOGINCH: asyncio.Queue()}
        self.spec = asyncio.Queue()  # (uuid, data) párok

    def cb(self, uuid):
        if uuid in (CONTROL, LOGINCH):
            def _cb2(_s, data):
                self.q[uuid].put_nowait(bytes(data))
            return _cb2
        # minden más csatorna a közös spec sorba (címkézve) — így bármelyiken jön a válasz, látjuk
        def _cb(_s, data):
            self.spec.put_nowait((uuid, bytes(data)))
        return _cb


async def get(q, t=8.0):
    return await asyncio.wait_for(q.get(), t)


# ---- login (0x0016 csatorna) ----
async def send_typed(cl, bus, type_id, payload):
    n = (len(payload) + FRAME - 1) // FRAME
    await cl.write_gatt_char(LOGINCH, bytes([0, 0, 0, type_id, n & 0xFF, n >> 8]), response=False)
    if (await get(bus.q[LOGINCH])) != RCV_RDY:
        raise RuntimeError("nem RCV_RDY")
    for i in range(0, len(payload), FRAME):
        await cl.write_gatt_char(LOGINCH, bytes([i // FRAME + 1, 0]) + payload[i:i + FRAME], response=False)
    if (await get(bus.q[LOGINCH])) != RCV_OK:
        raise RuntimeError("nem RCV_OK")


async def recv_typed(cl, bus):
    hdr = await get(bus.q[LOGINCH])
    n = hdr[4] + 0x100 * hdr[5]
    await cl.write_gatt_char(LOGINCH, RCV_RDY, response=False)
    buf = b""
    for _ in range(n):
        buf += (await get(bus.q[LOGINCH]))[2:]
    await cl.write_gatt_char(LOGINCH, RCV_OK, response=False)
    return buf


async def a4_handshake(cl, bus):
    """Csatorna-transport init: 0xA4 -> CONTROL, MNG válasz, MNG_ACK a LOGINCH-en.
    Visszaadja a negociált (maxPkgNum, DMTU)-t."""
    await cl.write_gatt_char(CONTROL, bytes([A4]), response=False)
    b = await get(bus.q[LOGINCH], 4.0)
    if len(b) >= 6 and b[0] == 0 and b[1] == 0 and b[2] == MNG:
        pkgnum, dmtu = b[4], b[5]
        ack = bytes([0, 0, MNG_ACK, b[3], pkgnum, dmtu])
        await cl.write_gatt_char(LOGINCH, ack, response=False)
        await asyncio.sleep(0.8)  # hagyjuk lecsengeni az A4 utóforgalmat
        for q in (bus.q[LOGINCH], bus.q[CONTROL]):  # a maradék kereteket eldobjuk
            while not q.empty():
                q.get_nowait()
        return pkgnum, dmtu
    raise RuntimeError(f"A4: nem MNG válasz: {b.hex()}")


class LoginRejected(RuntimeError):
    """A roller elutasította a logint (0x22/0x23): hibás PIN / kulcs, vagy nem ez a roller."""


async def login(cl, bus, ltmk, crc_order="little"):
    priv = ec.generate_private_key(ec.SECP256R1(), default_backend())
    our_pub = priv.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)[1:]
    await cl.write_gatt_char(CONTROL, LOGIN_START, response=False)
    await send_typed(cl, bus, 3, our_pub)
    remote = await recv_typed(cl, bus)
    if len(remote) != 64:
        raise RuntimeError("rossz roller pubkey")
    peer = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), b"\x04" + remote)
    shared = priv.exchange(ec.ECDH(), peer)
    derived = HKDF(algorithm=SHA256(), length=64, salt=SALT, info=INFO,
                   backend=default_backend()).derive(shared + ltmk)
    crc = (zlib.crc32(remote) & 0xFFFFFFFF).to_bytes(4, crc_order)
    proof = AESCCM(derived[16:32], tag_length=4).encrypt(CCM_NONCE, crc, None)
    await send_typed(cl, bus, 5, proof)
    cfm = await get(bus.q[CONTROL], 8.0)
    if cfm and cfm[0] == CFM_OK:
        return Keys(derived)
    if cfm and cfm[0] in (CFM_FAIL, 0x23):
        raise LoginRejected(f"login elutasítva: {cfm.hex()}")
    raise RuntimeError(f"login sikertelen: {cfm.hex() if cfm else 'nincs válasz'}")


async def open_session(target, ltmk, crc_order):
    """Csatlakozás + értesítések + A4 + login: (kliens, bus, kulcsok). Hibánál bont."""
    cl = BleakClient(target, timeout=20.0)
    await cl.connect()
    print("Csatlakozva.")
    try:
        bus = Bus()
        extra = ["00000017-0000-1000-8000-00805f9b34fb",
                 "00000018-0000-1000-8000-00805f9b34fb",
                 "0000001c-0000-1000-8000-00805f9b34fb"]
        for u in [CONTROL, LOGINCH, SPEC_WRITE, SPEC_NOTIFY] + extra:
            try:
                await cl.start_notify(u, bus.cb(u))
            except Exception as e:
                print(f"  (notify {u[4:8]} kihagyva: {e})")
        await asyncio.sleep(0.4)
        pkgnum, dmtu = await a4_handshake(cl, bus)
        print(f"A4 OK (maxPkg={pkgnum}, DMTU={dmtu}).")
        keys = await login(cl, bus, ltmk, crc_order)
        print("✅ Login OK.")
        return cl, bus, keys
    except BaseException:
        await cl.disconnect()
        raise


# ---- SPEC csatorna (0x001a/0x001b) ----
def enc_spec(keys, frame):
    nonce = keys.app_iv + bytes(4) + keys.counter.to_bytes(4, "little")
    ct = AESCCM(keys.app_key, tag_length=4).encrypt(nonce, frame, None)
    out = bytes([keys.counter & 0xFF, (keys.counter >> 8) & 0xFF]) + ct
    keys.counter += 1
    return out


def dec_spec(keys, payload):
    counter = payload[0] | (payload[1] << 8)
    nonce = keys.dev_iv + bytes(4) + counter.to_bytes(4, "little")
    return AESCCM(keys.dev_key, tag_length=4).decrypt(nonce, payload[2:], None)


def spec_header(total, tid, op):
    lenflag = (total | 0x2000) & 0xFFFF
    return bytes([lenflag & 0xFF, lenflag >> 8, tid & 0xFF, tid >> 8, op, 1])


def build_get(siid, piid, tid=1, op=2):
    # t2336 MiOT property-get: [len|0x2000][txn][op=2][count=1][siid u8, piid u16]
    # (a t2336 az OLVASÁShoz op=2-t vár; válasz op=3. Az írás op=0, válasz op=1.)
    body = bytes([siid, piid & 0xFF, piid >> 8])
    return spec_header(6 + len(body), tid, op) + body


def build_set(siid, piid, type_code, value, tid=1):
    tl = (type_code << 12) | len(value)
    body = bytes([siid, piid & 0xFF, piid >> 8, tl & 0xFF, tl >> 8]) + value
    return spec_header(6 + len(body), tid, 0) + body


async def spec_request(cl, bus, keys, frame, timeout=8.0):
    payload = enc_spec(keys, frame)
    chunks = [payload[i:i + FRAME] for i in range(0, len(payload), FRAME)]
    fc = len(chunks)
    # 1) CTR a SPEC_WRITE-ra
    await cl.write_gatt_char(SPEC_WRITE, bytes([0, 0, CTR, SPEC_CHANNEL, fc & 0xFF, fc >> 8]), response=False)
    resp = {}
    resp_fc = None
    sent = False
    loop = asyncio.get_event_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        try:
            src, b = await asyncio.wait_for(bus.spec.get(), deadline - loop.time())
        except asyncio.TimeoutError:
            break
        if os.environ.get("SCOOTER_DEBUG"):
            print(f"    <- 0x{src[4:8]} {b.hex(' ')}")
        is_ctrl = len(b) >= 3 and b[0] == 0 and b[1] == 0
        if is_ctrl and b[2] == ACK:
            status = b[3] if len(b) > 3 else -1
            if status == 0x01 and not sent:
                sent = True
                for n in range(1, fc + 1):
                    await cl.write_gatt_char(SPEC_WRITE, bytes([n & 0xFF, n >> 8]) + chunks[n - 1], response=False)
                    await asyncio.sleep(0.03)
            elif status == MNG_ACK:
                i = 4
                while i + 1 < len(b):
                    seq = b[i] | (b[i + 1] << 8)
                    await cl.write_gatt_char(SPEC_WRITE, bytes([seq & 0xFF, seq >> 8]) + chunks[seq - 1], response=False)
                    await asyncio.sleep(0.03)
                    i += 2
        elif is_ctrl and b[2] == CTR:
            # a roller válasz-CTR-je (akármelyik SPEC csatornán) — ACK vissza ugyanoda
            resp_fc = (b[4] | (b[5] << 8)) if len(b) >= 6 else (b[4] if len(b) > 4 else 0)
            resp_ch = src
            await cl.write_gatt_char(src, bytes([0, 0, ACK, 1]), response=False)
        elif not is_ctrl and len(b) >= 2:
            seq = b[0] | (b[1] << 8)
            if 1 <= seq <= 0xFFFF:
                resp[seq] = b[2:]
                if resp_fc is not None and len(resp) >= resp_fc:
                    await cl.write_gatt_char(src, bytes([0, 0, ACK, 0]), response=False)
                    assembled = b"".join(resp[k] for k in sorted(resp))
                    return dec_spec(keys, assembled)
    return None  # (a 0x001b nem olvasható, poll-read nem opció)


async def mcu_gate(cl, bus, timeout=3.0):
    """A valós Mi Home a SPEC előtt olvassa a 0x001c-t (verzió). Lehet, hogy ez
    'nyitja' a SPEC-választ a t2336-on. Pontosan a capture szerint: W 00 00, W 01 00."""
    async def next_1c(t):
        loop = asyncio.get_event_loop(); dl = loop.time() + t
        while loop.time() < dl:
            try:
                src, b = await asyncio.wait_for(bus.spec.get(), dl - loop.time())
            except asyncio.TimeoutError:
                return None
            if src == MCU_INFO:
                return b
        return None
    await cl.write_gatt_char(MCU_INFO, bytes([0, 0]), response=False)
    r1 = await next_1c(timeout)
    if os.environ.get("SCOOTER_DEBUG"):
        print(f"    [1c] W 00 00 -> {r1.hex(' ') if r1 else 'nincs'}")
    await cl.write_gatt_char(MCU_INFO, bytes([1, 0]), response=False)
    r2 = await next_1c(timeout)
    if os.environ.get("SCOOTER_DEBUG"):
        print(f"    [1c] W 01 00 -> {r2.hex(' ') if r2 else 'nincs'}")
    # a maradék 0x001c/egyéb kereteket dobjuk a SPEC előtt
    while not bus.spec.empty():
        bus.spec.get_nowait()
    return r2


async def poll_read_response(cl, keys):
    """A választ GATT read-del olvassuk a 0x001b-ről (ha a notify nem kézbesít)."""
    seen = set()
    resp = {}
    resp_fc = None
    for _ in range(15):
        try:
            rb = bytes(await cl.read_gatt_char(SPEC_NOTIFY))
        except Exception as e:
            if os.environ.get("SCOOTER_DEBUG"):
                print(f"    [poll read hiba] {e}")
            break
        if rb and rb not in seen:
            seen.add(rb)
            if os.environ.get("SCOOTER_DEBUG"):
                print(f"    [poll N] {rb.hex(' ')}")
            if len(rb) >= 6 and rb[0] == 0 and rb[1] == 0 and rb[2] == CTR:
                resp_fc = rb[4] | (rb[5] << 8)
                await cl.write_gatt_char(SPEC_NOTIFY, bytes([0, 0, ACK, 1]), response=False)
            elif len(rb) >= 2 and not (rb[0] == 0 and rb[1] == 0):
                seq = rb[0] | (rb[1] << 8)
                resp[seq] = rb[2:]
                if resp_fc is not None and len(resp) >= resp_fc:
                    await cl.write_gatt_char(SPEC_NOTIFY, bytes([0, 0, ACK, 0]), response=False)
                    return dec_spec(keys, b"".join(resp[k] for k in sorted(resp)))
        await asyncio.sleep(0.15)
    return None


async def spec_request_retry(cl, bus, keys, frame, timeout=8.0):
    """A roller néha némán eldob egy kérést (a referencia is így kezeli): egy retry."""
    pt = await spec_request(cl, bus, keys, frame, timeout)
    if pt is None:
        await asyncio.sleep(0.2)
        pt = await spec_request(cl, bus, keys, frame, timeout)
    return pt


def parse_set_status(pt):
    if not pt or len(pt) < 11:
        return -1
    return pt[9] | (pt[10] << 8)


def parse_get_value(pt):
    if not pt or len(pt) < 11:
        return None
    status = pt[9] | (pt[10] << 8)
    if status != 0 or len(pt) < 13:
        return None
    tl = pt[11] | (pt[12] << 8)
    vlen = tl & 0x0FFF
    return pt[13:13 + vlen] if len(pt) >= 13 + vlen else b""


def interp_value(v):
    """Nyers érték emberi olvasata: hex + egész (LE) + float (4B) + ASCII, ha értelmes."""
    parts = [v.hex()]
    if 1 <= len(v) <= 4:
        parts.append(f"u={int.from_bytes(v, 'little')}")
    if len(v) == 4:
        parts.append(f"f={struct.unpack('<f', v)[0]:.3f}")
    if len(v) >= 2 and all(32 <= b < 127 for b in v):
        parts.append(f'ascii="{v.decode()}"')
    return "  ".join(parts)


def decode_prop(raw, kind, scale):
    """Nyers érték -> valós érték a PROPS típusa és skálája szerint."""
    if raw is None or len(raw) == 0:
        return None
    if kind == "str":
        return raw.rstrip(b"\x00").decode("ascii", "replace")
    if kind == "i8":
        return (raw[0] - 256 if raw[0] >= 128 else raw[0]) * scale
    if kind == "f":
        return struct.unpack("<f", raw)[0] * scale if len(raw) == 4 else None
    return int.from_bytes(raw, "little") * scale  # u8/u16/bool


async def read_prop(cl, bus, keys, siid, piid):
    """Egy property kiolvasása és dekódolása a PROPS szerint (ismeretlennél nyers int)."""
    raw = parse_get_value(await spec_request_retry(cl, bus, keys, build_get(siid, piid)))
    name, kind, scale, unit = PROPS.get((siid, piid), (f"{siid},{piid}", "u", 1, ""))
    return decode_prop(raw, kind, scale), unit


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["scan", "status", "lock", "unlock", "get", "set",
                                    "propsweep", "listen", "monitor"])
    ap.add_argument("siid", nargs="?", type=int, help="get/set-hez")
    ap.add_argument("piid", nargs="?", type=int, help="get/set-hez")
    ap.add_argument("value", nargs="?", help="set-hez (pl. 1 vagy 0)")
    ap.add_argument("--crc", choices=["little", "big"], default="little")
    ap.add_argument("--rescan", action="store_true",
                    help="a rögzített roller (SCOOTER_BLE_ADDRESS) helyett újrakeresés és újra rögzítés")
    args = ap.parse_args()

    if args.cmd == "scan":
        await scan(args.siid or 8)
        return

    here = os.path.dirname(os.path.abspath(__file__))
    env_path = os.path.join(here, "secrets", "scooter.env")
    if not os.path.exists(env_path):
        sys.exit("Hiányzik a secrets/scooter.env (minta: secrets/scooter.env.example).")
    env = load_env(env_path)
    ztoken = bytes.fromhex(env["SCOOTER_PSK_LOCAL"])
    # fix cím opcionális (macOS-en CoreBluetooth-UUID, Linuxon MAC); különben keresés
    address = env.get("SCOOTER_BLE_ADDRESS") or env.get("SCOOTER_BLE_MAC_MACOS")
    pin = getpass("Roller PIN (nem látszik): ")
    d = Cipher(algorithms.AES(hashlib.md5(pin.encode()).digest()), modes.CBC(LTMK_IV),
               backend=default_backend()).decryptor()
    ltmk = d.update(ztoken) + d.finalize()

    if address and not args.rescan:
        cl, bus, keys = await open_session(address, ltmk, args.crc)
    else:
        # első beállítás (vagy --rescan): a közeli t2336-ok közül az, amelyik elfogadja a kulcsot
        print("Roller keresése...")
        candidates = await find_scooters()
        if not candidates:
            sys.exit("Nem találom a rollert. Kapcsold be, és a telefonos app ne legyen rácsatlakozva.")
        dev, (cl, bus, keys) = await first_accepting(
            candidates, lambda d: open_session(d, ltmk, args.crc))
        save_env_value(env_path, "SCOOTER_BLE_ADDRESS", dev.address)
        print(f"Roller rögzítve: {dev.address} (secrets/scooter.env, SCOOTER_BLE_ADDRESS)")
    try:
        await asyncio.sleep(0.3)
        await mcu_gate(cl, bus)   # 0x001c verzió-olvasás (kapu-hipotézis)
        await asyncio.sleep(0.3)
        if args.cmd in ("lock", "unlock"):
            val = b"\x01" if args.cmd == "lock" else b"\x00"
            pt = await spec_request_retry(cl, bus, keys, build_set(LOCK_SIID, LOCK_PIID, 0, val))
            print(f"   nyers válasz: {pt.hex() if pt else 'nincs (timeout)'}")
            st = parse_set_status(pt)
            print(f"✅ {args.cmd.upper()} sikeres." if st == 0
                  else f"⚠️ SET status={st} (0=OK; 4097/0x1001 = ismeretlen property).")
        elif args.cmd == "set":
            val = int(args.value).to_bytes(1, "little")
            pt = await spec_request_retry(cl, bus, keys, build_set(args.siid, args.piid, 0, val))
            print(f"   set({args.siid},{args.piid})={args.value} -> status={parse_set_status(pt)} nyers={pt.hex() if pt else 'nincs'}")
        elif args.cmd == "propsweep":
            # a t2336 olvasható MIoT property-inek feltérképezése (op=2)
            # tartomány: propsweep [max_siid] [max_piid]  (alap 16 x 24)
            max_s = args.siid or 16
            max_p = args.piid or 24
            found = []
            for siid in range(1, max_s + 1):
                for piid in range(1, max_p + 1):
                    while not bus.spec.empty():
                        bus.spec.get_nowait()
                    pt = await spec_request(cl, bus, keys, build_get(siid, piid), timeout=1.4)
                    v = parse_get_value(pt) if pt else None
                    if v is not None:
                        print(f"  ({siid},{piid}): {interp_value(v)}")
                        found.append((siid, piid, v.hex()))
                    await asyncio.sleep(0.08)
            print(f"\n  Olvasható property-k ({len(found)} db): "
                  f"{[(s, p) for s, p, _ in found]}")
        elif args.cmd == "listen":
            # passzív: van-e spontán telemetria-push a notify-csatornákon?
            import time
            secs = args.siid or 20
            print(f"  Hallgatózás {secs}s — mozgasd/pörgesd a rollert, ha van rá mód...")
            t0 = time.time()
            while time.time() - t0 < secs:
                try:
                    src, b = await asyncio.wait_for(bus.spec.get(), 1.0)
                except asyncio.TimeoutError:
                    continue
                line = f"  [{time.time()-t0:5.1f}] {src[4:8]} raw={b.hex()}"
                try:
                    dec = dec_spec(keys, b)
                    line += f"  dec={dec.hex()}"
                except Exception:
                    pass
                print(line)
            print("  vége.")
        elif args.cmd == "monitor":
            # élő telemetria-műszerfal: a dinamikus property-ket ciklusban pollozzuk,
            # a PROPS szerint dekódolva (W/A/V valós időben változik menet közben).
            import time
            secs = args.siid or 60
            cols = [(1, 6, "W"), (1, 5, "A"), (1, 4, "V"), (2, 1, "km/h"),
                    (1, 2, "akku%"), (1, 9, "trip_km"), (3, 3, "°C"), (2, 2, "zár")]
            print("   idő   " + "  ".join(f"{h:>7}" for *_, h in cols))
            t0 = time.time()
            while time.time() - t0 < secs:
                cells = []
                for s, p, _ in cols:
                    while not bus.spec.empty():
                        bus.spec.get_nowait()
                    raw = parse_get_value(await spec_request(cl, bus, keys, build_get(s, p), timeout=1.0))
                    name, kind, scale, unit = PROPS[(s, p)]
                    v = decode_prop(raw, kind, scale)
                    if v is None:
                        cells.append("-")
                    elif isinstance(v, float):
                        cells.append(f"{v:.1f}")
                    else:
                        cells.append(str(v))
                print(f"  {time.time()-t0:5.1f}  " + "  ".join(f"{c:>7}" for c in cells))
            print("  vége.")
        elif args.cmd == "get":
            raw = parse_get_value(await spec_request_retry(cl, bus, keys, build_get(args.siid, args.piid)))
            name, kind, scale, unit = PROPS.get((args.siid, args.piid), (f"{args.siid},{args.piid}", "u", 1, ""))
            val = decode_prop(raw, kind, scale)
            suffix = f" {unit}" if (unit and val is not None) else ""
            print(f"   {name} ({args.siid},{args.piid}) = {val}{suffix}   nyers={raw.hex() if raw else 'nincs'}")
        else:  # status
            batt, _ = await read_prop(cl, bus, keys, 1, 2)
            lk, _ = await read_prop(cl, bus, keys, 2, 2)
            soh, _ = await read_prop(cl, bus, keys, 3, 12)
            rng, _ = await read_prop(cl, bus, keys, 1, 7)
            total, _ = await read_prop(cl, bus, keys, 2, 6)
            temp, _ = await read_prop(cl, bus, keys, 3, 3)
            fw, _ = await read_prop(cl, bus, keys, 4, 5)
            print(f"Akku:      {batt}%   (SOH {soh}%)")
            print(f"Zár:       {'ZÁRVA' if lk else 'NYITVA'}")
            print(f"Hatótáv:   {rng:.1f} km" if rng is not None else "Hatótáv:   ?")
            print(f"Össz-km:   {total:.1f} km" if total is not None else "Össz-km:   ?")
            print(f"Hőmérs.:   {temp}°C")
            print(f"Firmware:  {fw}")
    finally:
        await cl.disconnect()
        print("Lekapcsolódva.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as e:
        sys.exit(f"Hiba: {e}")
