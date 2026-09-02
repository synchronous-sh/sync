#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVICE_NAME="${KEEP_DEVICE_NAME:-ark}"
BUNDLE_ID="com.synchronous.keep"
DERIVED="$ROOT/.derived-iphone"
TEAM="X6F8273N97"

python3 - "$DEVICE_NAME" <<'PY'
import json, subprocess, sys
name = sys.argv[1]
raw = subprocess.check_output(["xcrun", "devicectl", "list", "devices", "--json-output", "-"], stderr=subprocess.DEVNULL)
# older/newer CLI may not support --json-output -
PY

# Parse devices without requiring json (devicectl table + xcodebuild)
COREDEVICE_ID="$(xcrun devicectl list devices 2>/dev/null | awk -v name="$DEVICE_NAME" 'NR>2 && $1==name { print $3; exit }')"

if [[ -z "${COREDEVICE_ID:-}" ]]; then
  echo "iPhone '$DEVICE_NAME' is not available."
  echo "Plug it in (or connect via network), unlock it, and tap Trust."
  xcrun devicectl list devices
  exit 1
fi

echo "Device: $DEVICE_NAME ($COREDEVICE_ID)"
echo "Building for your iPhone…"

xcodebuild \
  -project sync.xcodeproj \
  -scheme sync \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  build

APP="$DERIVED/Build/Products/Debug-iphoneos/sync.app"
if [[ ! -d "$APP" ]]; then
  echo "Build finished but sync.app is missing at:"
  echo "  $APP"
  exit 1
fi

echo "Installing…"
xcrun devicectl device install app --device "$COREDEVICE_ID" "$APP"

echo "Launching…"
xcrun devicectl device process launch --device "$COREDEVICE_ID" "$BUNDLE_ID"

echo ""
echo "sync should be on your phone."
echo "First time only: Settings → General → VPN & Device Management → trust Aadi Katyal."
