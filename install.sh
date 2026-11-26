#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: Antigravity Pilot is only supported on macOS." >&2
  exit 1
fi

for cmd in curl python3 hdiutil ditto shasum codesign; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found." >&2
    exit 1
  fi
done

GITHUB_REPO="${GITHUB_REPO:-TakeshiKaneshivo/antigravity-pilot-macos}"
APP_VERSION="${APP_VERSION:-}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP_NAME="Antigravity Pilot.app"
EXPECTED_BUNDLE_ID="com.takeshikaneshivo.antigravity-pilot.macos"

if [[ -z "${MANIFEST_URL:-}" ]]; then
  if [[ -n "$APP_VERSION" ]]; then
    CLEAN_VER="${APP_VERSION#v}"
    MANIFEST_URL="https://github.com/${GITHUB_REPO}/releases/download/v${CLEAN_VER}/latest.json"
  else
    MANIFEST_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/latest.json"
  fi
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ag-pilot-install.XXXXXX")"
MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "==> Fetching release manifest from ${MANIFEST_URL}..."
MANIFEST_PATH="${TMP_DIR}/latest.json"
curl -fsSL --retry 2 --connect-timeout 15 "$MANIFEST_URL" -o "$MANIFEST_PATH"

META_OUT="$(python3 - "$MANIFEST_PATH" "$(sw_vers -productVersion)" <<'PYEOF'
import json
import sys

manifest_path, current_os = sys.argv[1:3]
with open(manifest_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

version = str(data.get("version") or "").strip()
min_macos = str(data.get("minMacOS") or "13.0").strip()
dmg = data.get("dmg") or {}
url = str(dmg.get("url") or "").strip()
file_name = str(dmg.get("fileName") or "").strip()
sha256 = str(dmg.get("sha256") or "").strip().lower()
size = int(dmg.get("size") or 0)

def ver_tuple(raw):
    parts = []
    for seg in raw.split("-")[0].split(".")[:3]:
        parts.append(int(seg))
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)

if not version or not url or not file_name or len(sha256) != 64:
    raise SystemExit("Invalid latest.json manifest fields.")

if ver_tuple(current_os) < ver_tuple(min_macos):
    raise SystemExit(f"macOS {min_macos}+ is required (current: {current_os}).")

if "/" in file_name or ".." in file_name:
    raise SystemExit("Invalid DMG file name in manifest.")

print(f"{version}\t{url}\t{file_name}\t{sha256}\t{size}")
PYEOF
)"

IFS=$'\t' read -r VERSION DMG_URL DMG_FILE EXPECTED_SHA256 EXPECTED_SIZE <<<"$META_OUT"

DMG_PATH="${TMP_DIR}/${DMG_FILE}"
echo "==> Downloading ${DMG_FILE} (v${VERSION})..."
curl -fL --retry 2 --connect-timeout 15 --progress-bar "$DMG_URL" -o "$DMG_PATH"

ACTUAL_SIZE="$(stat -f%z "$DMG_PATH")"
if [[ "$EXPECTED_SIZE" -gt 0 && "$ACTUAL_SIZE" -ne "$EXPECTED_SIZE" ]]; then
  echo "Error: size mismatch (expected ${EXPECTED_SIZE} bytes, got ${ACTUAL_SIZE} bytes)." >&2
  exit 1
fi

ACTUAL_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print tolower($1)}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Error: SHA-256 mismatch!" >&2
  echo "  expected: ${EXPECTED_SHA256}" >&2
  echo "  actual:   ${ACTUAL_SHA256}" >&2
  exit 1
fi
echo "==> SHA-256 verified (${ACTUAL_SHA256})."

echo "==> Mounting disk image..."
ATTACH_PLIST="${TMP_DIR}/attach.plist"
hdiutil attach -nobrowse -readonly -noautoopen -plist "$DMG_PATH" > "$ATTACH_PLIST"
MOUNT_POINT="$(python3 - "$ATTACH_PLIST" <<'PYEOF'
import plistlib
import sys

with open(sys.argv[1], "rb") as fh:
    pl = plistlib.load(fh)

for ent in pl.get("system-entities", []):
    mp = ent.get("mount-point")
    if mp:
        print(mp)
        sys.exit(0)
raise SystemExit("Mount point not found in hdiutil output.")
PYEOF
)"

SRC_APP="${MOUNT_POINT}/${APP_NAME}"
if [[ ! -d "$SRC_APP" ]]; then
  echo "Error: '${APP_NAME}' not found inside mounted DMG." >&2
  exit 1
fi

STAGED_APP="${TMP_DIR}/${APP_NAME}"
echo "==> Extracting and verifying app bundle..."
ditto "$SRC_APP" "$STAGED_APP"
xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true

ACTUAL_BUNDLE_ID="$(defaults read "${STAGED_APP}/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
if [[ "$ACTUAL_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Error: unexpected Bundle ID '${ACTUAL_BUNDLE_ID}' (expected '${EXPECTED_BUNDLE_ID}')." >&2
  exit 1
fi

codesign --verify --deep --strict "$STAGED_APP"

mkdir -p "$INSTALL_DIR" 2>/dev/null || true
TARGET_APP="${INSTALL_DIR}/${APP_NAME}"
BACKUP_APP="${INSTALL_DIR}/.Antigravity-Pilot.app.backup-$$"

run_priv() {
  if [[ -w "$INSTALL_DIR" && ( ! -e "$TARGET_APP" || -w "$TARGET_APP" ) ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

if [[ ! -w "$INSTALL_DIR" || ( -e "$TARGET_APP" && ! -w "$TARGET_APP" ) ]]; then
  echo "==> Administrator permission is required to install into ${INSTALL_DIR}..."
fi

echo "==> Installing to ${TARGET_APP}..."
if [[ -e "$TARGET_APP" ]]; then
  run_priv rm -rf "$BACKUP_APP"
  run_priv mv "$TARGET_APP" "$BACKUP_APP"
fi

if ! run_priv mv "$STAGED_APP" "$TARGET_APP"; then
  if [[ -e "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
    run_priv mv "$BACKUP_APP" "$TARGET_APP" || true
  fi
  echo "Error: failed to install into ${TARGET_APP}." >&2
  exit 1
fi

if [[ -e "$BACKUP_APP" ]]; then
  run_priv rm -rf "$BACKUP_APP" || true
fi

run_priv xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
run_priv touch "$TARGET_APP" "${TARGET_APP}/Contents/Info.plist" 2>/dev/null || true

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$TARGET_APP" 2>/dev/null || true
fi

hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
MOUNT_POINT=""

echo "==> Installed Antigravity Pilot v${VERSION} to ${TARGET_APP}"
