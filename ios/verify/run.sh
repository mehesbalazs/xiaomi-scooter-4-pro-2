#!/bin/bash
# A Swift kriptó/protokoll-mag ellenőrzése a scooter.py referencia-értékei ellen,
# plusz az újrapróbálás-szabályok és a BLE keret-sor viselkedése.
# Nem kell hozzá Xcode, csak a swift toolchain (CommandLineTools elég).
# A teszt-bináris ideiglenes mappába fordul, és utána törlődik (nem marad a projektben).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../ScooterLink/ScooterLink"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT
swiftc "$src/ScooterCrypto.swift" "$src/ScooterProtocol.swift" "$src/Retry.swift" "$src/FrameQueue.swift" \
  "$here/main.swift" -o "$tmp/verify"
"$tmp/verify"
