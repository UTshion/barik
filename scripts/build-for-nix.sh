#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_DIR="$ROOT_DIR/barik"
DERIVED_DATA="$PROJECT_DIR/.derivedData-nix"
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Barik.app"

echo "[barik] Building with Xcode (Release)..."
xcodebuild \
  -project "$PROJECT_DIR/Barik.xcodeproj" \
  -scheme Barik \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=- \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "[barik] Build succeeded but Barik.app was not found: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/Barik.app" "$DIST_DIR/Barik.zip"
cp -R "$APP_PATH" "$DIST_DIR/Barik.app"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DIST_DIR/Barik.zip"

echo "[barik] Exported:"
echo "  - $DIST_DIR/Barik.app"
echo "  - $DIST_DIR/Barik.zip"
echo
echo "You can now run:"
echo "  darwin-rebuild switch --flake .#default"
