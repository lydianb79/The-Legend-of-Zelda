#!/bin/bash
# Build "Zelda Recomp.app" from your own ROM dump.
#   ./build.sh                         # uses the first *.nes found next to this folder (or inside it)
#   ./build.sh "/path/to/Legend of Zelda.nes"
# Steps: 6502 -> C static recompilation, Swift/Metal build, .app bundle assembly, ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

ROM="${1:-}"
if [ -z "$ROM" ]; then
  ROM="$(ls -1 "$HERE"/*.nes "$HERE"/../*.nes 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$ROM" ] || [ ! -f "$ROM" ]; then
  echo "error: no ROM given and no .nes file found next to the project." >&2
  echo "usage: ./build.sh /path/to/zelda.nes" >&2
  exit 1
fi
ROM="$(cd "$(dirname "$ROM")" && pwd)/$(basename "$ROM")"
echo "==> ROM: $ROM"

command -v swift >/dev/null || { echo "error: Swift toolchain not found. Install Xcode or run: xcode-select --install" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found (comes with the Xcode command line tools)" >&2; exit 1; }

COVERAGE_ARGS=(--coverage Tools/seeds)
USER_COV="$HOME/Library/Application Support/ZeldaRecomp/coverage"
if [ -d "$USER_COV" ]; then COVERAGE_ARGS+=(--coverage "$USER_COV"); fi

echo "==> Recompiling 6502 code to C"
python3 Tools/recompile.py --rom "$ROM" --out Sources/NESCore/generated/recomp_gen.c "${COVERAGE_ARGS[@]}"

echo "==> Building (swift build -c release) — the generated C takes a minute to compile"
swift build -c release --product ZeldaRecomp

BIN="$(swift build -c release --show-bin-path)/ZeldaRecomp"
APP="$HERE/build/Zelda Recomp.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ZeldaRecomp"
# App icon: build a full-resolution .icns from the 1024px master with sips/iconutil, fall back to the prebuilt one.
# Pick a variant with ICON=<name>, e.g.  ICON=2_dungeon ./build.sh   (see Resources/icons/)
ICON_MASTER="$HERE/Resources/icon_1024.png"
if [ -n "${ICON:-}" ]; then
  if [ -f "$HERE/Resources/icons/${ICON%.png}.png" ]; then ICON_MASTER="$HERE/Resources/icons/${ICON%.png}.png"; echo "==> Icon: ${ICON%.png}"
  else echo "warning: icon variant '$ICON' not found in Resources/icons — using the default"; fi
fi
if [ -f "$ICON_MASTER" ] && command -v iconutil >/dev/null && command -v sips >/dev/null; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$ICON_MASTER" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$ICON_MASTER" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/"
elif [ -f "$HERE/Resources/AppIcon.icns" ]; then
  cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi

ROM_XML="$(printf '%s' "$ROM" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Zelda Recomp</string>
  <key>CFBundleDisplayName</key><string>Zelda Recomp</string>
  <key>CFBundleIdentifier</key><string>local.zeldarecomp.app</string>
  <key>CFBundleExecutable</key><string>ZeldaRecomp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>GCSupportsControllerUserInteraction</key><true/>
  <key>ZRDefaultROMPath</key><string>$ROM_XML</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed (app will still run locally)"
touch "$APP"   # make Finder/Dock pick up the new icon
echo "==> Done: $APP"
echo "    open \"$APP\""
