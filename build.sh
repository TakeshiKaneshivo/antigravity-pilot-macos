#!/usr/bin/env bash
set -euo pipefail

BUILD_START_TS=$(date +%s)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"

MAKE_DMG=0
BUILD_WEB=0
NATIVE_ONLY=0
CLEAN_BUILD=0
NOTES_FILE=""
usage() {
  cat <<'EOF'
Usage:
  ./build.sh [--dmg] [--native] [--clean] [--build-web] [--notes-file <path>] [-h|--help]

Options:
  --dmg                Also create a compressed .dmg installer and latest.json in build/
  --native             Build only for the host CPU architecture (fast local builds; with --dmg, produces a single-arch DMG, not universal)
  --clean              Remove build/.cache before building to force a full cold rebuild
  --build-web          Rebuild src/McpAppWeb/dist/dashboard.html via npm before packaging
  --notes-file <path>  Optional JSON (language map) or Markdown/text release notes for latest.json
  -h, --help           Show this help.

Environment overrides:
  APP_VERSION  Bundle short version & DMG version (default: 0.2.0)
  MIN_MACOS    Minimum supported macOS version (default: 13.0)
  ARCHS        Space-separated architectures (default: "arm64 x86_64", or host arch with --native)
  SDKROOT      macOS SDK path (default: xcrun --show-sdk-path)
  GITHUB_REPO  GitHub owner/repo for release URLs (default: TakeshiKaneshivo/antigravity-pilot-macos)
EOF
}

while (($#)); do
  case "$1" in
    --dmg)
      MAKE_DMG=1
      shift
      ;;
    --native)
      NATIVE_ONLY=1
      shift
      ;;
    --clean)
      CLEAN_BUILD=1
      shift
      ;;
    --build-web)
      BUILD_WEB=1
      shift
      ;;
    --notes-file)
      if [[ $# -lt 2 ]]; then
        echo "--notes-file requires a path argument" >&2
        exit 2
      fi
      NOTES_FILE="$2"
      shift 2
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

CACHE_DIR="$BUILD_DIR/.cache"
HASH_CACHE_DIR="$CACHE_DIR/hashes"
ICON_CACHE_DIR="$CACHE_DIR/icons"
MODULE_CACHE_DIR="$CACHE_DIR/module-cache"
SWIFT_CACHE_DIR="$CACHE_DIR/swift"

if [[ "$CLEAN_BUILD" -eq 1 ]]; then
  rm -rf "$CACHE_DIR"
fi
mkdir -p "$BUILD_DIR" "$HASH_CACHE_DIR" "$ICON_CACHE_DIR" "$MODULE_CACHE_DIR" "$SWIFT_CACHE_DIR"

CC="${CC:-clang}"
SWIFTC="${SWIFTC:-swiftc}"
APP_VERSION="${APP_VERSION:-0.2.0}"
MIN_MACOS="${MIN_MACOS:-13.0}"
if [[ "$NATIVE_ONLY" -eq 1 ]]; then
  ARCHS="$(uname -m)"
else
  ARCHS="${ARCHS:-arm64 x86_64}"
fi
SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
GITHUB_REPO="${GITHUB_REPO:-TakeshiKaneshivo/antigravity-pilot-macos}"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [[ "$MAKE_DMG" -eq 1 ]] && ! command -v "$SWIFTC" >/dev/null 2>&1; then
  echo "--dmg requires swiftc ($SWIFTC not found)" >&2
  exit 1
fi

read -r -a ARCH_LIST <<< "$ARCHS"
if [[ "${#ARCH_LIST[@]}" -eq 0 ]]; then
  echo "ARCHS cannot be empty" >&2
  exit 1
fi

CLANG_ARCH_FLAGS=()
for arch in "${ARCH_LIST[@]}"; do
  CLANG_ARCH_FLAGS+=(-arch "$arch")
done

CFLAGS=(
  -O2
  -Wall
  -Wextra
  -Werror
  -Wno-deprecated-declarations
  -mmacosx-version-min="$MIN_MACOS"
  -isysroot "$SDKROOT"
)

hash_files_and_key() {
  local key_string="$1"
  shift
  {
    printf '%s\n' "$key_string"
    if [[ $# -gt 0 ]]; then
      shasum -a 256 "$@"
    fi
  } | shasum -a 256 | awk '{print $1}'
}

build_c_target() {
  local name="$1"
  local output_path="$2"
  local src_path="$3"
  shift 3
  local extra_flags=("$@")
  local cc_ver
  cc_ver="$("$CC" --version 2>/dev/null | head -n 1 || echo "$CC")"
  local key_str
  key_str="cc=${cc_ver}|cflags=${CFLAGS[*]}|arch=${CLANG_ARCH_FLAGS[*]}|extra=${extra_flags[*]-}|out=${output_path}"
  local new_hash
  new_hash="$(hash_files_and_key "$key_str" "$src_path")"
  local hash_file="$HASH_CACHE_DIR/${name}.sha256"

  if [[ -f "$output_path" && -f "$hash_file" ]] && [[ "$(cat "$hash_file")" == "$new_hash" ]]; then
    printf '[cache hit] %s\n' "$name"
    return 0
  fi

  "$CC" "${CFLAGS[@]}" "${CLANG_ARCH_FLAGS[@]}" ${extra_flags[@]+"${extra_flags[@]}"} \
    -o "$output_path" \
    "$src_path"

  printf '%s\n' "$new_hash" > "${hash_file}.tmp"
  mv "${hash_file}.tmp" "$hash_file"
  printf '[built] %s\n' "$name"
}

generate_output_file_map() {
  local ofm_path="$1"
  local obj_dir="$2"
  shift 2
  python3 - "$ROOT" "$ofm_path" "$obj_dir" "$@" <<'PYEOF'
import json
import os
import sys

root, ofm_path, obj_dir, *files = sys.argv[1:]
root_real = os.path.abspath(root)
data = {
    "": {
        "swift-dependencies": os.path.join(obj_dir, "master.swiftdeps")
    }
}
used_stems = set()
for f in files:
    abs_f = os.path.abspath(f)
    rel = os.path.relpath(abs_f, root_real)
    stem = rel.replace(os.sep, "__").replace(" ", "_")
    if stem in used_stems:
        idx = 1
        while f"{stem}_{idx}" in used_stems:
            idx += 1
        stem = f"{stem}_{idx}"
    used_stems.add(stem)
    data[f] = {
        "object": os.path.join(obj_dir, f"{stem}.o"),
        "swift-dependencies": os.path.join(obj_dir, f"{stem}.swiftdeps"),
        "dependencies": os.path.join(obj_dir, f"{stem}.d"),
    }

os.makedirs(os.path.dirname(ofm_path), exist_ok=True)
tmp_path = ofm_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp_path, ofm_path)
PYEOF
}

build_swift_arch() {
  local target_name="$1"
  local arch="$2"
  shift 2
  local extra_flags=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      shift
      break
    fi
    extra_flags+=("$1")
    shift
  done
  local files=("$@")

  local target_cache="$SWIFT_CACHE_DIR/${target_name}/${arch}"
  local obj_dir="$target_cache/obj"
  local arch_bin="$target_cache/${target_name}"
  local ofm_path="$target_cache/output-file-map.json"
  local env_hash_file="$target_cache/env.sha256"
  local inputs_hash_file="$target_cache/inputs.sha256"

  local swift_ver
  swift_ver="$("$SWIFTC" --version 2>/dev/null | tr '\n' ' ' || echo "$SWIFTC")"
  local env_str
  env_str="swift=${swift_ver}|sdk=${SDKROOT}|min=${MIN_MACOS}|arch=${arch}|extra=${extra_flags[*]-}"
  local env_key
  env_key="$(hash_files_and_key "$env_str")"
  local inputs_key
  inputs_key="$(hash_files_and_key "$env_key" "${files[@]}")"

  if [[ -f "$arch_bin" && -f "$inputs_hash_file" ]] && [[ "$(cat "$inputs_hash_file")" == "$inputs_key" ]]; then
    printf '[cache hit] %s (%s)\n' "$target_name" "$arch"
    return 0
  fi

  if [[ ! -f "$env_hash_file" ]] || [[ "$(cat "$env_hash_file")" != "$env_key" ]]; then
    rm -rf "$target_cache"
  fi

  mkdir -p "$obj_dir"
  generate_output_file_map "$ofm_path" "$obj_dir" "${files[@]}"

  "$SWIFTC" -incremental -O \
    -j "$NCPU" \
    -module-cache-path "$MODULE_CACHE_DIR" \
    -output-file-map "$ofm_path" \
    ${extra_flags[@]+"${extra_flags[@]}"} \
    -sdk "$SDKROOT" \
    -target "${arch}-apple-macos${MIN_MACOS}" \
    -lsqlite3 \
    -o "$arch_bin" \
    "${files[@]}"

  printf '%s\n' "$env_key" > "${env_hash_file}.tmp"
  mv "${env_hash_file}.tmp" "$env_hash_file"
  printf '%s\n' "$inputs_key" > "${inputs_hash_file}.tmp"
  mv "${inputs_hash_file}.tmp" "$inputs_hash_file"
  printf '[built] %s (%s)\n' "$target_name" "$arch"
}

build_c_target "libantigravity_proxy.dylib" "$BUILD_DIR/libantigravity_proxy.dylib" "$ROOT/src/antigravity_proxy.c" -dynamiclib
build_c_target "test_client" "$BUILD_DIR/test_client" "$ROOT/tests/test_client.c"
build_c_target "AntigravityProxyLauncher" "$BUILD_DIR/AntigravityProxyLauncher" "$ROOT/src/launcher.c"

if command -v "$SWIFTC" >/dev/null 2>&1; then
  if [[ "$BUILD_WEB" -eq 1 ]]; then
    if ! command -v npm >/dev/null 2>&1; then
      echo "--build-web requires npm" >&2
      exit 1
    fi
    npm --prefix "$ROOT/src/McpAppWeb" run build
  fi

  MCP_HTML="$ROOT/src/McpAppWeb/dist/dashboard.html"
  if [[ ! -f "$MCP_HTML" ]]; then
    echo "Missing prebuilt MCP dashboard HTML at $MCP_HTML (run with --build-web or npm run build)" >&2
    exit 1
  fi

  MCP_SOURCES=(
    "$ROOT/src/App/Models/Localization.swift"
    "$ROOT/src/App/Models/MonitorModels.swift"
    "$ROOT/src/App/Models/ProxyModels.swift"
    "$ROOT/src/App/Services/AppSupportStore.swift"
    "$ROOT/src/App/Services/LanguageServerClient.swift"
    "$ROOT/src/App/Services/LocalSessionIndexReader.swift"
    "$ROOT/src/App/Services/ProxyHealthService.swift"
    "$ROOT/src/App/Services/TranscriptScanner.swift"
    "$ROOT/src/McpServer/MCPProtocol.swift"
    "$ROOT/src/McpServer/main.swift"
  )

  MCP_BINS=()
  for arch in "${ARCH_LIST[@]}"; do
    build_swift_arch "antigravity-pilot-mcp" "$arch" -- "${MCP_SOURCES[@]}"
    MCP_BINS+=("$SWIFT_CACHE_DIR/antigravity-pilot-mcp/${arch}/antigravity-pilot-mcp")
  done

  if [[ "${#MCP_BINS[@]}" -gt 1 ]]; then
    lipo -create -output "$BUILD_DIR/antigravity-pilot-mcp" "${MCP_BINS[@]}"
  else
    cp "${MCP_BINS[0]}" "$BUILD_DIR/antigravity-pilot-mcp"
  fi
  chmod +x "$BUILD_DIR/antigravity-pilot-mcp"

  SWIFT_SOURCES=()
  while IFS= read -r swift_file; do
    SWIFT_SOURCES+=("$swift_file")
  done < <(find "$ROOT/src/App" -type f -name '*.swift' | sort)

  if [[ "${#SWIFT_SOURCES[@]}" -eq 0 ]]; then
    echo "No Swift sources found in $ROOT/src/App" >&2
    exit 1
  fi

  SWIFT_BINS=()
  for arch in "${ARCH_LIST[@]}"; do
    build_swift_arch "AntigravityProxyBuilder" "$arch" -parse-as-library -- "${SWIFT_SOURCES[@]}"
    SWIFT_BINS+=("$SWIFT_CACHE_DIR/AntigravityProxyBuilder/${arch}/AntigravityProxyBuilder")
  done

  if [[ "${#SWIFT_BINS[@]}" -gt 1 ]]; then
    lipo -create -output "$BUILD_DIR/AntigravityProxyBuilder" "${SWIFT_BINS[@]}"
  else
    cp "${SWIFT_BINS[0]}" "$BUILD_DIR/AntigravityProxyBuilder"
  fi

  APP_DIR="$BUILD_DIR/Antigravity Pilot.app"
  APP_CONTENTS="$APP_DIR/Contents"
  APP_MACOS="$APP_CONTENTS/MacOS"
  APP_RESOURCES="$APP_CONTENTS/Resources"
  rm -rf "$APP_DIR"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"

  cp "$BUILD_DIR/AntigravityProxyBuilder" "$APP_MACOS/AntigravityProxyBuilder"
  cp "$BUILD_DIR/AntigravityProxyLauncher" "$APP_RESOURCES/AntigravityProxyLauncher"
  cp "$BUILD_DIR/libantigravity_proxy.dylib" "$APP_RESOURCES/libantigravity_proxy.dylib"
  cp "$BUILD_DIR/antigravity-pilot-mcp" "$APP_RESOURCES/antigravity-pilot-mcp"
  cp "$MCP_HTML" "$APP_RESOURCES/pilot-mcp-dashboard.html"
  cp "$ROOT/icon.png" "$APP_RESOURCES/icon.png"
  if [[ -f "$ROOT/pricing-catalog.json" ]]; then
    cp "$ROOT/pricing-catalog.json" "$APP_RESOURCES/pricing-catalog.json"
  fi
  if [[ -f "$ROOT/menubar-icon.png" ]]; then
    MENUBAR_HASH="$(hash_files_and_key "menubar-v1" "$ROOT/menubar-icon.png")"
    MENUBAR_HASH_FILE="$HASH_CACHE_DIR/menubar-icon.sha256"
    if [[ -f "$ICON_CACHE_DIR/menubar-icon.png" && -f "$ICON_CACHE_DIR/menubar-icon@2x.png" && -f "$ICON_CACHE_DIR/menubar-icon@3x.png" && -f "$MENUBAR_HASH_FILE" ]] && [[ "$(cat "$MENUBAR_HASH_FILE")" == "$MENUBAR_HASH" ]]; then
      printf '[cache hit] menubar-icon\n'
    else
      sips -z 18 18 "$ROOT/menubar-icon.png" --out "$ICON_CACHE_DIR/menubar-icon.png" >/dev/null
      sips -z 36 36 "$ROOT/menubar-icon.png" --out "$ICON_CACHE_DIR/menubar-icon@2x.png" >/dev/null
      sips -z 54 54 "$ROOT/menubar-icon.png" --out "$ICON_CACHE_DIR/menubar-icon@3x.png" >/dev/null
      printf '%s\n' "$MENUBAR_HASH" > "${MENUBAR_HASH_FILE}.tmp"
      mv "${MENUBAR_HASH_FILE}.tmp" "$MENUBAR_HASH_FILE"
      printf '[built] menubar-icon\n'
    fi
    cp "$ICON_CACHE_DIR/menubar-icon.png" "$APP_RESOURCES/menubar-icon.png"
    cp "$ICON_CACHE_DIR/menubar-icon@2x.png" "$APP_RESOURCES/menubar-icon@2x.png"
    cp "$ICON_CACHE_DIR/menubar-icon@3x.png" "$APP_RESOURCES/menubar-icon@3x.png"
  fi
  chmod +x "$APP_RESOURCES/antigravity-pilot-mcp"

  ICNS_HASH="$(hash_files_and_key "icns-v1" "$ROOT/icon.png")"
  ICNS_HASH_FILE="$HASH_CACHE_DIR/icon-icns.sha256"
  CACHED_ICNS="$ICON_CACHE_DIR/antigravity-pilot.icns"
  if [[ -f "$CACHED_ICNS" && -f "$ICNS_HASH_FILE" ]] && [[ "$(cat "$ICNS_HASH_FILE")" == "$ICNS_HASH" ]]; then
    printf '[cache hit] antigravity-pilot.icns\n'
  else
    ICONSET="$BUILD_DIR/antigravity-pilot.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    sips -z 16 16 "$ROOT/icon.png" --out "$ICONSET/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ROOT/icon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ROOT/icon.png" --out "$ICONSET/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ROOT/icon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ROOT/icon.png" --out "$ICONSET/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ROOT/icon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ROOT/icon.png" --out "$ICONSET/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ROOT/icon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ROOT/icon.png" --out "$ICONSET/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$ROOT/icon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET" -o "$CACHED_ICNS"
    rm -rf "$ICONSET"
    printf '%s\n' "$ICNS_HASH" > "${ICNS_HASH_FILE}.tmp"
    mv "${ICNS_HASH_FILE}.tmp" "$ICNS_HASH_FILE"
    printf '[built] antigravity-pilot.icns\n'
  fi
  cp "$CACHED_ICNS" "$APP_RESOURCES/antigravity-pilot.icns"

  cat >"$APP_CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Antigravity Pilot</string>
  <key>CFBundleExecutable</key>
  <string>AntigravityProxyBuilder</string>
  <key>CFBundleIdentifier</key>
  <string>com.takeshikaneshivo.antigravity-pilot.macos</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Antigravity Pilot</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleIconFile</key>
  <string>antigravity-pilot.icns</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS}</string>
</dict>
</plist>
EOF
  echo "APPL????" >"$APP_CONTENTS/PkgInfo"
  codesign --force --sign - "$APP_RESOURCES/antigravity-pilot-mcp"
  codesign --force --deep --sign - "$APP_DIR"
  codesign --verify --deep --strict "$APP_DIR"
fi

DMG_PATH=""
MANIFEST_PATH=""
if [[ "$MAKE_DMG" -eq 1 ]]; then
  if [[ "${#ARCH_LIST[@]}" -gt 1 ]]; then
    ARCH_LABEL="universal"
  else
    ARCH_LABEL="${ARCH_LIST[0]}"
  fi
  MACOS_MAJOR="${MIN_MACOS%%.*}"
  DMG_PATH="$BUILD_DIR/Antigravity-Pilot-v${APP_VERSION}-macOS${MACOS_MAJOR}-${ARCH_LABEL}.dmg"
  DMG_STAGING="$BUILD_DIR/dmg-staging"
  rm -rf "$DMG_STAGING" "$DMG_PATH"
  mkdir -p "$DMG_STAGING"
  ditto "$APP_DIR" "$DMG_STAGING/Antigravity Pilot.app"
  ln -s /Applications "$DMG_STAGING/Applications"
  hdiutil create -volname "Antigravity Pilot" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
  rm -rf "$DMG_STAGING"
  hdiutil verify "$DMG_PATH"

  DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  DMG_SIZE="$(stat -f%z "$DMG_PATH")"
  DMG_FILENAME="$(basename "$DMG_PATH")"
  MANIFEST_PATH="$BUILD_DIR/latest.json"

  python3 - "$MANIFEST_PATH" "$APP_VERSION" "$MIN_MACOS" "$GITHUB_REPO" "$DMG_FILENAME" "$DMG_SHA256" "$DMG_SIZE" "$NOTES_FILE" <<'PYEOF'
import datetime
import json
import os
import sys

out_path, version, min_macos, repo, file_name, sha256_hex, size_str, notes_file = sys.argv[1:9]
tag = f"v{version}"
published_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

notes = {
    "zh-Hans": f"Antigravity Pilot {tag} 更新包。",
    "zh-Hant": f"Antigravity Pilot {tag} 更新套件。",
    "en": f"Antigravity Pilot {tag} release.",
    "ru": f"Выпуск Antigravity Pilot {tag}."
}

if notes_file:
    if not os.path.isfile(notes_file):
        raise SystemExit(f"Notes file not found: {notes_file}")
    with open(notes_file, "r", encoding="utf-8") as fh:
        raw = fh.read().strip()
    if raw:
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                notes = {str(k): str(v) for k, v in parsed.items() if str(v).strip()}
            else:
                notes = {k: raw for k in notes}
        except json.JSONDecodeError:
            notes = {k: raw for k in notes}

manifest = {
    "version": version,
    "tag": tag,
    "publishedAt": published_at,
    "minMacOS": min_macos,
    "dmg": {
        "fileName": file_name,
        "url": f"https://github.com/{repo}/releases/download/{tag}/{file_name}",
        "sha256": sha256_hex,
        "size": int(size_str),
    },
    "releasePageUrl": f"https://github.com/{repo}/releases/tag/{tag}",
    "notes": notes,
}

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PYEOF
fi

BUILD_ELAPSED=$(( $(date +%s) - BUILD_START_TS ))
printf 'Built in %ss:\n' "$BUILD_ELAPSED"
printf '  %s\n' "$BUILD_DIR/libantigravity_proxy.dylib"
printf '  %s\n' "$BUILD_DIR/test_client"
printf '  %s\n' "$BUILD_DIR/AntigravityProxyLauncher"
if [[ -f "$BUILD_DIR/antigravity-pilot-mcp" ]]; then
  printf '  %s\n' "$BUILD_DIR/antigravity-pilot-mcp"
fi
if [[ -d "$BUILD_DIR/Antigravity Pilot.app" ]]; then
  printf '  %s\n' "$BUILD_DIR/Antigravity Pilot.app"
fi
if [[ -n "$DMG_PATH" && -f "$DMG_PATH" ]]; then
  printf '  %s\n' "$DMG_PATH"
  printf 'SHA256:\n  %s\n' "$DMG_SHA256"
fi
if [[ -n "$MANIFEST_PATH" && -f "$MANIFEST_PATH" ]]; then
  printf '  %s\n' "$MANIFEST_PATH"
fi
