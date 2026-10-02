#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./script/release.sh VERSION

Build, Developer ID sign, notarize, staple, package, and verify a local release.
VERSION must use the form X.Y.Z, for example 1.3.0.

Optional environment overrides:
  MACOS_SIGNING_IDENTITY  Developer ID Application identity
  MACOS_NOTARY_PROFILE    notarytool Keychain profile
  RELEASE_OUTPUT_DIR      artifact directory (defaults to dist)
  RELEASE_ALLOW_DIRTY=1   allow a dirty Git worktree (testing only)
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || { usage >&2; exit 64; }
[[ "$1" != "-h" && "$1" != "--help" ]] || { usage; exit 0; }

VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must use X.Y.Z"

APP_NAME="LMStudioStatusWidget"
BUNDLE_ID="local.codex.LMStudioStatusWidget"
MIN_SYSTEM_VERSION="15.0"
ARCHITECTURE="$(uname -m)"
[[ "$ARCHITECTURE" == "arm64" ]] || die "only arm64 release artifacts are currently supported"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="AppIcon.icns"
APP_ICON_SOURCE="$ROOT_DIR/Assets/$APP_ICON_NAME"
FINAL_ZIP="$OUTPUT_DIR/$APP_NAME-$VERSION-macOS-$ARCHITECTURE.zip"
CHECKSUM_FILE="$FINAL_ZIP.sha256"
NOTARY_DIR="$OUTPUT_DIR/notary"
SUBMISSION_ZIP="$NOTARY_DIR/$APP_NAME-$VERSION-macOS-$ARCHITECTURE-submitted.zip"
NOTARY_RESULT="$NOTARY_DIR/$APP_NAME-$VERSION-notary-result.json"
NOTARY_LOG="$NOTARY_DIR/$APP_NAME-$VERSION-notary-log.json"
# Fingerprint selects G2 when Developer ID certificates share a name.
SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-D548540E7FE1BD9B3C4518CC02D8786E1BFEB885}"
NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-LMStudioStatusWidget-notary}"
BUILD_NUMBER="${RELEASE_BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD)}"

for command_name in swift codesign security xcrun ditto unzip shasum spctl plutil file; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done

[[ -f "$APP_ICON_SOURCE" ]] || die "missing app icon: $APP_ICON_SOURCE"

if [[ "${RELEASE_ALLOW_DIRTY:-0}" != "1" ]]; then
  [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]] || \
    die "Git worktree is not clean; commit or stash changes before a release"
fi

security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null || \
  die "Developer ID signing identity is unavailable: $SIGNING_IDENTITY"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"

"$ROOT_DIR/script/verify_license_material.sh" "$ROOT_DIR"

echo "==> Testing Swift package"
(cd "$ROOT_DIR" && swift test)

echo "==> Building optimized $ARCHITECTURE release"
(cd "$ROOT_DIR" && swift build -c release)
BUILD_BINARY="$(cd "$ROOT_DIR" && swift build -c release --show-bin-path)/$APP_NAME"
[[ -x "$BUILD_BINARY" ]] || die "release executable not found: $BUILD_BINARY"
file "$BUILD_BINARY" | grep -F "arm64" >/dev/null || die "release executable is not arm64"

mkdir -p "$OUTPUT_DIR" "$NOTARY_DIR"
[[ "$APP_BUNDLE" == "$OUTPUT_DIR/$APP_NAME.app" ]] || die "refusing unsafe app path"
rm -rf "$APP_BUNDLE"
rm -f "$FINAL_ZIP" "$CHECKSUM_FILE" "$SUBMISSION_ZIP" "$NOTARY_RESULT" "$NOTARY_LOG"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_NAME"
for notice in LICENSE LICENSING.md LICENSE-MIT; do
  cp "$ROOT_DIR/$notice" "$APP_RESOURCES/$notice"
done
"$ROOT_DIR/script/verify_license_material.sh" "$APP_RESOURCES"
chmod 755 "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST"

echo "==> Signing with Developer ID"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -dv --verbose=4 "$APP_BUNDLE"

echo "==> Creating notarization submission"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$SUBMISSION_ZIP"
unzip -t "$SUBMISSION_ZIP" >/dev/null

echo "==> Submitting to Apple Notary Service"
set +e
xcrun notarytool submit "$SUBMISSION_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --timeout 30m \
  --output-format json >"$NOTARY_RESULT"
NOTARY_EXIT=$?
set -e

cat "$NOTARY_RESULT"
SUBMISSION_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"

if [[ -n "$SUBMISSION_ID" ]]; then
  xcrun notarytool log "$SUBMISSION_ID" \
    --keychain-profile "$NOTARY_PROFILE" \
    "$NOTARY_LOG" || true
fi

[[ $NOTARY_EXIT -eq 0 && "$NOTARY_STATUS" == "Accepted" ]] || \
  die "notarization failed with status '${NOTARY_STATUS:-unknown}'; inspect $NOTARY_LOG"

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

echo "==> Creating final distribution archive"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$FINAL_ZIP"
unzip -t "$FINAL_ZIP" >/dev/null

VERIFY_DIR="$(mktemp -d /private/tmp/lmstudio-widget-release-verify.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$FINAL_ZIP" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/$APP_NAME.app"
"$ROOT_DIR/script/verify_license_material.sh" "$EXTRACTED_APP/Contents/Resources"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$EXTRACTED_APP/Contents/Info.plist")" == "$VERSION" ]] || \
  die "extracted app version does not match $VERSION"
file "$EXTRACTED_APP/Contents/MacOS/$APP_NAME" | grep -F "arm64" >/dev/null || \
  die "extracted app executable is not arm64"
codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
codesign -dv --verbose=4 "$EXTRACTED_APP"
xcrun stapler validate "$EXTRACTED_APP"
spctl --assess --type execute --verbose=4 "$EXTRACTED_APP"

(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$FINAL_ZIP")") | tee "$CHECKSUM_FILE"

echo
echo "Release artifact ready: $FINAL_ZIP"
echo "Notary submission: $SUBMISSION_ID"
echo "Checksum file: $CHECKSUM_FILE"
echo "Nothing was uploaded to GitHub. Publish separately after review."
