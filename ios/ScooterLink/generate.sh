#!/bin/bash
# Az Xcode-projekt generálása a project.yml-ből, a signing.env értékeivel.
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -f signing.env ]; then
  echo "Hiányzik a signing.env — másold a signing.env.example-t, és töltsd ki." >&2
  exit 1
fi
set -a; source signing.env; set +a
: "${DEVELOPMENT_TEAM:?nincs megadva a signing.env-ben}"
: "${BUNDLE_ID_PREFIX:?nincs megadva a signing.env-ben}"
xcodegen generate
