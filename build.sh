#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
OUTPUT="$ROOT_DIR/fmproxy-bin"
PRODUCT="$BUILD_DIR/Build/Products/Release/FMProxy"

xcodebuild \
  -project "$ROOT_DIR/FMProxy.xcodeproj" \
  -scheme FMProxy \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -x "$PRODUCT" ]]; then
  echo "Build failed: executable not found at $PRODUCT" >&2
  exit 1
fi

cp "$PRODUCT" "$OUTPUT"
strip -S -x "$OUTPUT"
chmod +x "$OUTPUT"

printf 'Built Apple Silicon binary: %s\n' "$OUTPUT"
