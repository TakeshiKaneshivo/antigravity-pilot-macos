#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_APP="/Applications/Antigravity.app"
DEST_APP="$ROOT/Antigravity-Pilot.app"
PROXY_URL="socks5://127.0.0.1:7890"
ENV_PROXY_URL="http://127.0.0.1:7890"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

usage() {
  cat <<'EOF'
Usage:
  ./prepare-app-copy.sh [options]

Options:
  --source PATH       Source Antigravity.app. Default: /Applications/Antigravity.app
  --dest PATH         Destination app copy. Default: ./Antigravity-Pilot.app
  --proxy URL         Dylib SOCKS5 proxy URL. Default: socks5://127.0.0.1:7890
  --env-proxy URL     HTTP_PROXY/HTTPS_PROXY/ALL_PROXY URL. Default: http://127.0.0.1:7890
  --replace           Remove existing destination before copying.
  -h, --help          Show this help.
EOF
}

REPLACE=0
while (($#)); do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || { echo "Missing --source value" >&2; exit 2; }
      SOURCE_APP="$2"
      shift 2
      ;;
    --dest)
      [[ $# -ge 2 ]] || { echo "Missing --dest value" >&2; exit 2; }
      DEST_APP="$2"
      shift 2
      ;;
    --proxy)
      [[ $# -ge 2 ]] || { echo "Missing --proxy value" >&2; exit 2; }
      PROXY_URL="$2"
      shift 2
      ;;
    --env-proxy)
      [[ $# -ge 2 ]] || { echo "Missing --env-proxy value" >&2; exit 2; }
      ENV_PROXY_URL="$2"
      shift 2
      ;;
    --replace)
      REPLACE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$SOURCE_APP" ]] || { echo "Source app not found: $SOURCE_APP" >&2; exit 1; }

if [[ ! -f "$ROOT/build/libantigravity_proxy.dylib" || ! -x "$ROOT/build/AntigravityProxyLauncher" ]]; then
  "$ROOT/build.sh"
fi

if [[ -e "$DEST_APP" ]]; then
  if [[ "$REPLACE" -eq 1 ]]; then
    rm -rf "$DEST_APP"
  else
    echo "Destination already exists: $DEST_APP" >&2
    echo "Use --replace to recreate it." >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$DEST_APP")" "$ROOT/build"

echo "Copying Antigravity.app..."
ditto "$SOURCE_APP" "$DEST_APP"
mkdir -p "$DEST_APP/Contents/MacOS" "$DEST_APP/Contents/Resources"

LAUNCHER_EXECUTABLE="$DEST_APP/Contents/MacOS/AntigravityProxyLauncher"
cp "$ROOT/build/AntigravityProxyLauncher" "$LAUNCHER_EXECUTABLE"
chmod +x "$LAUNCHER_EXECUTABLE"
cp "$ROOT/build/libantigravity_proxy.dylib" "$DEST_APP/Contents/Resources/libantigravity_proxy.dylib"

SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
SOURCE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
cat >"$DEST_APP/Contents/Resources/proxy.env" <<EOF
AG_PROXY=$PROXY_URL
AG_PROXY_LOG=0
AG_PROXY_TIMEOUT_MS=15000
HTTP_PROXY=$ENV_PROXY_URL
HTTPS_PROXY=$ENV_PROXY_URL
ALL_PROXY=$ENV_PROXY_URL
http_proxy=$ENV_PROXY_URL
https_proxy=$ENV_PROXY_URL
all_proxy=$ENV_PROXY_URL
NO_PROXY=localhost,127.0.0.1,::1,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.local,<local>
no_proxy=localhost,127.0.0.1,::1,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.local,<local>
NODE_USE_ENV_PROXY=1
EOF
if [[ -n "$SOURCE_VERSION" ]]; then
  printf 'AG_SOURCE_VERSION=%s\n' "$SOURCE_VERSION" >>"$DEST_APP/Contents/Resources/proxy.env"
fi
if [[ -n "$SOURCE_BUILD" ]]; then
  printf 'AG_SOURCE_BUILD=%s\n' "$SOURCE_BUILD" >>"$DEST_APP/Contents/Resources/proxy.env"
fi

PROXY_ICON_NAME="antigravity-pilot.icns"
PROXY_ICON_PATH="$DEST_APP/Contents/Resources/$PROXY_ICON_NAME"
CUSTOM_ICON_PNG="$ROOT/icon.png"
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
ICON_SOURCE=""
if [[ -n "$ICON_FILE" ]]; then
  ICON_SOURCE="$SOURCE_APP/Contents/Resources/$ICON_FILE"
  [[ "$ICON_SOURCE" == *.icns ]] || ICON_SOURCE="$ICON_SOURCE.icns"
fi

generate_icns_from_png() {
  local source_png="$1"
  local output_icns="$2"
  local tmp_dir iconset
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/antigravity-pilot-icon.XXXXXX")"
  iconset="$tmp_dir/icon.iconset"
  mkdir -p "$iconset"

  sips -z 16 16 "$source_png" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$source_png" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$source_png" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$source_png" --out "$iconset/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$iconset" -o "$output_icns"
  cp "$iconset/icon_512x512@2x.png" "${output_icns%.icns}.preview.png"
  rm -rf "$tmp_dir"
}

if [[ -f "$CUSTOM_ICON_PNG" ]]; then
  generate_icns_from_png "$CUSTOM_ICON_PNG" "$PROXY_ICON_PATH"
elif [[ -n "$ICON_SOURCE" && -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$PROXY_ICON_PATH"
else
  echo "Warning: cannot generate proxy icon; falling back to source icon." >&2
fi

ASAR_ICON_SOURCE="${PROXY_ICON_PATH%.icns}.preview.png"
if [[ -f "$CUSTOM_ICON_PNG" ]]; then
  ASAR_ICON_SOURCE="$CUSTOM_ICON_PNG"
fi
if [[ -x "$PYTHON_BIN" && -f "$ASAR_ICON_SOURCE" && -f "$DEST_APP/Contents/Resources/app.asar" ]]; then
  "$PYTHON_BIN" "$ROOT/scripts/patch_asar_icon.py" \
    --asar "$DEST_APP/Contents/Resources/app.asar" \
    --icon "$ASAR_ICON_SOURCE" \
    --info-plist "$DEST_APP/Contents/Info.plist"
fi
rm -f "${PROXY_ICON_PATH%.icns}.preview.png"

APP_PLIST="$DEST_APP/Contents/Info.plist"
# Keep CFBundleName as "Antigravity" so Electron locates Contents/Frameworks/Antigravity Helper*.app.
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable AntigravityProxyLauncher' "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string AntigravityProxyLauncher' "$APP_PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.google.antigravity.pilot.runtime' "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.google.antigravity.pilot.runtime' "$APP_PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Antigravity Pilot' "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Antigravity Pilot' "$APP_PLIST"
if [[ -f "$PROXY_ICON_PATH" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $PROXY_ICON_NAME" "$APP_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $PROXY_ICON_NAME" "$APP_PLIST"
fi
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$APP_PLIST" 2>/dev/null || true

set_helper_icon_and_id() {
  local helper_name="$1"
  local helper_id="$2"
  HELPER_APP="$DEST_APP/Contents/Frameworks/$helper_name"
  HELPER_PLIST="$HELPER_APP/Contents/Info.plist"
  if [[ -f "$HELPER_PLIST" ]]; then
    mkdir -p "$HELPER_APP/Contents/Resources"
    if [[ -f "$PROXY_ICON_PATH" ]]; then
      cp "$PROXY_ICON_PATH" "$HELPER_APP/Contents/Resources/$PROXY_ICON_NAME"
      /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $PROXY_ICON_NAME" "$HELPER_PLIST" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $PROXY_ICON_NAME" "$HELPER_PLIST"
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $helper_id" "$HELPER_PLIST" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $helper_id" "$HELPER_PLIST"
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$HELPER_PLIST" 2>/dev/null || true
  fi
}

set_helper_icon_and_id "Antigravity Helper.app" "com.google.antigravity.pilot.runtime.helper"
set_helper_icon_and_id "Antigravity Helper (GPU).app" "com.google.antigravity.pilot.runtime.helper.GPU"
set_helper_icon_and_id "Antigravity Helper (Plugin).app" "com.google.antigravity.pilot.runtime.helper.Plugin"
set_helper_icon_and_id "Antigravity Helper (Renderer).app" "com.google.antigravity.pilot.runtime.helper.Renderer"

ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/antigravity-pilot-entitlements.XXXXXX.plist")"
trap 'rm -f "$ENTITLEMENTS"' EXIT
RAW_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$SOURCE_APP" 2>/dev/null || true)"
if [[ "$RAW_ENTITLEMENTS" == *"<?xml"* || "$RAW_ENTITLEMENTS" == *"<plist"* ]]; then
  if [[ "$RAW_ENTITLEMENTS" == *"<?xml"* ]]; then
    XML_BODY="<?xml${RAW_ENTITLEMENTS#*<?xml}"
  else
    XML_BODY="<plist${RAW_ENTITLEMENTS#*<plist}"
  fi
  printf '%s\n' "$XML_BODY" >"$ENTITLEMENTS"
  if /usr/libexec/PlistBuddy -c 'Print' "$ENTITLEMENTS" >/dev/null 2>&1; then
    for key in \
      com.apple.security.cs.allow-dyld-environment-variables \
      com.apple.security.cs.disable-library-validation \
      com.apple.security.cs.allow-jit; do
      /usr/libexec/PlistBuddy -c "Set :$key true" "$ENTITLEMENTS" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :$key bool true" "$ENTITLEMENTS"
    done
  else
    rm -f "$ENTITLEMENTS"
  fi
fi

if [[ ! -s "$ENTITLEMENTS" ]]; then
  cat >"$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key>
  <true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key>
  <true/>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.apple.security.device.camera</key>
  <true/>
</dict>
</plist>
EOF
fi

# Remove Squirrel/electron-updater config so the isolated runtime copy does not loop failing updates.
rm -f "$DEST_APP/Contents/Resources/app-update.yml"

echo "Removing quarantine attributes if present..."
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

echo "Ad-hoc signing Antigravity executable with DYLD injection entitlements..."
AG_BIN="$DEST_APP/Contents/MacOS/Antigravity"
if [[ -f "$AG_BIN" ]]; then
  TMP_SIGN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ag-sign.XXXXXX")"
  mv "$AG_BIN" "$TMP_SIGN_DIR/Antigravity"
  codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$TMP_SIGN_DIR/Antigravity"
  mv "$TMP_SIGN_DIR/Antigravity" "$AG_BIN"
  chmod +x "$AG_BIN"
  rmdir "$TMP_SIGN_DIR"
fi

echo "Ad-hoc signing frameworks, helpers, and native libraries..."
while IFS= read -r -d '' item; do
  if file "$item" | grep -q 'Mach-O'; then
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$item" >/dev/null 2>&1 || true
  fi
done < <(find "$DEST_APP/Contents/Frameworks" "$DEST_APP/Contents/Resources" -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' -o -name '*.node' \) -print0 2>/dev/null)

for fw in "$DEST_APP/Contents/Frameworks"/*.framework; do
  if [[ -e "$fw" ]]; then
    codesign --force --sign - "$fw"
  fi
done

for helper in "$DEST_APP/Contents/Frameworks"/Antigravity\ Helper*.app; do
  if [[ -e "$helper" ]]; then
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$helper"
  fi
done

echo "Ad-hoc signing app bundle with DYLD injection entitlements..."
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$DEST_APP"

echo "Verifying signature..."
codesign --verify --deep --strict "$DEST_APP"

touch "$DEST_APP" "$DEST_APP/Contents/Info.plist"
for helper in "$DEST_APP/Contents/Frameworks"/Antigravity\ Helper*.app; do
  if [[ -e "$helper" ]]; then
    touch "$helper" "$helper/Contents/Info.plist"
  fi
done
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f -R "$DEST_APP" >/dev/null 2>&1 || true
fi

echo "Prepared:"
echo "  $DEST_APP"
echo
echo "Entitlements:"
codesign -d --entitlements :- "$DEST_APP" 2>/dev/null || true
