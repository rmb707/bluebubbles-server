#!/bin/zsh
# Build the forked BlueBubbles server, sign it with the local Apple Development
# identity (stable identity keeps Full Disk Access/Accessibility grants), and
# install it to /Applications.
#
# Signing happens outside ~/Documents because iCloud Drive re-adds
# com.apple.FinderInfo / fileprovider xattrs, which codesign rejects.
set -euo pipefail

ROOT="${0:A:h:h}"
IDENTITY="${BB_SIGN_IDENTITY:-40AA004D0FFC1F79534D2C05761AD6C9582B62B0}"
WORK="${TMPDIR:-/tmp}/bb-server-sign"

source ~/.nvm/nvm.sh >/dev/null
nvm use 20.11 >/dev/null

cd "$ROOT"
if [[ "${1:-}" == "--with-ui" ]]; then
  npm run build-ui
fi

cd packages/server
npm run build
rm -rf releases/mac-arm64
CSC_IDENTITY_AUTO_DISCOVERY=false npx electron-builder build --mac dir --arm64 --publish never \
  --config ./scripts/electron-builder-config.js

rm -rf "$WORK" && mkdir -p "$WORK"
ditto --norsrc --noextattr --noacl releases/mac-arm64/BlueBubbles.app "$WORK/BlueBubbles.app"
cp scripts/entitlements.mac.plist "$WORK/ent.plist"
cd "$WORK"
xattr -cr BlueBubbles.app

# Sign inside-out: nested Mach-O binaries, then helper apps/frameworks, then the bundle.
find BlueBubbles.app/Contents -type f \( -name "*.dylib" -o -name "*.node" -o -perm +111 \) \
  ! -path "*/Contents/MacOS/BlueBubbles" -print0 |
  while IFS= read -r -d '' f; do
    file "$f" | grep -q Mach-O && codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$f" 2>&1 | grep -v replacing || true
  done
find BlueBubbles.app/Contents/Frameworks -maxdepth 1 \( -name "*.framework" -o -name "*.app" \) -print0 | sort -rz |
  while IFS= read -r -d '' b; do
    codesign --force --options runtime --timestamp=none --entitlements ent.plist -s "$IDENTITY" "$b" 2>&1 | grep -v replacing || true
  done
codesign --force --options runtime --timestamp=none --entitlements ent.plist -s "$IDENTITY" BlueBubbles.app 2>&1 | grep -v replacing || true
codesign -v --deep --strict BlueBubbles.app

osascript -e 'quit app "BlueBubbles"' 2>/dev/null || true
sleep 4
pkill -f "/Applications/BlueBubbles.app/Contents/MacOS/BlueBubbles" 2>/dev/null || true
sleep 1
rm -rf /Applications/BlueBubbles.app
ditto BlueBubbles.app /Applications/BlueBubbles.app
open /Applications/BlueBubbles.app
echo "Deployed $(codesign -dv /Applications/BlueBubbles.app 2>&1 | grep TeamIdentifier)"
