#!/usr/bin/env python3
"""A roller titkosított BLE-kulcsának lekérése a Xiaomi-felhőből (`/share/askbluetoothkey`).

A t2336 kulcsa PIN-védett (encrypt_type=1): a felhő a titkosított kulcsot adja, a
szkriptek (scooter.py, iOS-app) ezt a PIN-nel fejtik ki futásidőben:
    LTMK = AES-128-CBC-NoPad-decrypt(key=MD5(PIN), IV=7aa4…3800, ct=kulcs)

Használat (a Xiaomi-belépést a token_extractor kéri, a jelszó nem látszik):
    python tokens/get_ltmk.py --did <DID> --server <régió> [--save]

A DID-et és a régiót a `python tokens/token_extractor.py` eszközlistája mutatja.
--save: a kulcsot a secrets/scooter.env SCOOTER_PSK_LOCAL sorába írja (másolás nélkül).
"""

import argparse
import hashlib
import os
import sys

LTMK_IV = bytes.fromhex("7aa4c68c590d4031b980d98b41023800")
SERVERS = ["cn", "de", "us", "ru", "tw", "sg", "in", "i2"]
HERE = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(HERE, "..", "secrets", "scooter.env")


def aes_cbc_nopad_decrypt(key: bytes, iv: bytes, ct: bytes) -> bytes:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    d = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    return d.update(ct) + d.finalize()


def ltmk_from(key_hex: str, pin: str) -> bytes:
    """A PIN-védett felhőkulcsból az LTMK (a login-kulcs)."""
    return aes_cbc_nopad_decrypt(hashlib.md5(pin.encode()).digest(), LTMK_IV, bytes.fromhex(key_hex))


def save_env_value(path: str, key: str, value: str) -> None:
    """KEY=value beírása / cseréje egy .env-fájlban (a többi sor érintetlen)."""
    lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
    out, done = [], False
    for line in lines:
        if line.split("=", 1)[0].strip() == key:
            out.append(f"{key}={value}"); done = True
        else:
            out.append(line)
    if not done:
        out.append(f"{key}={value}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.chmod(path, 0o600)


def main() -> None:
    ap = argparse.ArgumentParser(description="A roller BLE-kulcsának lekérése a Xiaomi-felhőből.")
    ap.add_argument("--did", required=True, help="a roller eszköz-azonosítója (token_extractor listájából)")
    ap.add_argument("--server", required=True, choices=SERVERS, help="a fiók régiója, ahol a roller van")
    ap.add_argument("--save", action="store_true", help="SCOOTER_PSK_LOCAL beírása a secrets/scooter.env-be")
    args = ap.parse_args()

    sys.path.insert(0, HERE)
    sys.argv = ["get_ltmk"]                     # a token_extractor importkor saját argumentumokat olvas
    from token_extractor import PasswordXiaomiCloudConnector  # noqa: E402

    c = PasswordXiaomiCloudConnector()
    print("Belépés a Xiaomi-fiókba (a jelszó nem jelenik meg)...\n")
    if not c.login():
        sys.exit("Belépés sikertelen.")

    url = c.get_api_url(args.server) + "/share/askbluetoothkey"
    params = {"data": '{"type":"own","did":"' + args.did + '","keyid":0}'}
    res = c.execute_api_call_encrypted(url, params)
    if not res or res.get("code") != 0 or "result" not in res:
        sys.exit(f"A felhő nem adott érvényes választ: {res}")
    key_hex = res["result"].get("key")
    enc = int(res["result"].get("encrypt_type", 0))
    if not key_hex:
        sys.exit("Nincs 'key' a válaszban.")
    if enc != 1:
        sys.exit(f"Váratlan encrypt_type={enc} — a t2336 PIN-védett (1) kulcsot ad; más modell?")

    print(f"Titkosított BLE-kulcs ({len(key_hex) // 2} bájt) megvan.")
    if args.save:
        save_env_value(ENV_PATH, "SCOOTER_PSK_LOCAL", key_hex)
        print(f"Beírva: {os.path.normpath(ENV_PATH)} (SCOOTER_PSK_LOCAL)")
    else:
        print("\nSCOOTER_PSK_LOCAL=" + key_hex)
        print("\nEzt írd a secrets/scooter.env-be (vagy futtasd --save-vel), az iOS-appban pedig a")
        print("Beállítások › Felhőkulcs mezőbe. A PIN-t a szkriptek futásidőben kérik, nem tárolódik.")


if __name__ == "__main__":
    main()
