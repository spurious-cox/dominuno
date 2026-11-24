#!/bin/zsh
# Build Domin-Uno and install it on a paired device (unlocked, on the same Wi-Fi or plugged in).
#   ./install.sh             -> the first device in devices.local
#   ./install.sh <name>      -> that device from devices.local
#   ./install.sh <UDID>      -> any paired device
# devices.local (not in git) has one "name UDID" pair per line; `xcrun devicectl list devices` shows UDIDs.
set -e
cd "${0:A:h}"
DEV="${1:-}"
if [[ -f devices.local ]]; then
  if [[ -z "$DEV" ]]; then DEV=$(awk 'NF>=2 && $1 !~ /^#/ {print $2; exit}' devices.local)
  else FOUND=$(awk -v n="$DEV" '$1==n {print $2; exit}' devices.local); [[ -n "$FOUND" ]] && DEV="$FOUND"
  fi
fi
[[ -n "$DEV" ]] || { echo "usage: ./install.sh <device name or UDID>  (see devices.local)" >&2; exit 1; }
xcodegen generate >/dev/null
xcodebuild -project DominUno.xcodeproj -scheme DominUno -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build | grep -E 'error|BUILD (SUCCEEDED|FAILED)'
xcrun devicectl device install app --device "$DEV" build/Build/Products/Release-iphoneos/DominUno.app | tail -3
