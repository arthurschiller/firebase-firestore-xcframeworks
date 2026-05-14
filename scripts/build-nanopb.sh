#!/usr/bin/env bash
# Build nanopb.xcframework with added visionOS slices.
# Source: firebase/nanopb @ 2.30910.0 (matches Firebase 11.15.0 Package.resolved).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_build_common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/build/sources/nanopb"
GOOGLE_NPB="$REPO_ROOT/build/downloads/Firebase-extracted/Firebase/FirebaseAnalytics/nanopb.xcframework"
OUT="$REPO_ROOT/build/artifacts/nanopb"
SLICES="$REPO_ROOT/build/artifacts/nanopb-slices"

for p in "$SRC" "$GOOGLE_NPB"; do
  if [ ! -e "$p" ]; then echo "ERROR: missing $p"; exit 1; fi
done

rm -rf "$OUT" "$SLICES"
mkdir -p "$OUT" "$SLICES"

REF_SLICE="$GOOGLE_NPB/ios-arm64/nanopb.framework"

build_slice() {
  local sdk="$1" slice_name="$2" platform_name="$3" min_os="$4"
  local build_dir="$REPO_ROOT/build/artifacts/nanopb-build-$sdk"
  local framework_dir="$SLICES/$slice_name/nanopb.framework"

  echo ""
  echo "Building nanopb for $sdk (arm64)"

  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  cmake -S "$SRC" -B "$build_dir" \
    -G "Unix Makefiles" \
    "${CMAKE_CCACHE_ARGS[@]}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_os" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -Dnanopb_BUILD_GENERATOR=OFF

  cmake --build "$build_dir" --target protobuf-nanopb-static -j$PARALLEL_JOBS

  local lib
  lib="$(find "$build_dir" -name "libprotobuf-nanopb*.a" -type f | head -1)"
  if [ -z "$lib" ]; then
    echo "ERROR: libprotobuf-nanopb-static.a not found"; find "$build_dir" -name "*.a"; exit 1
  fi

  mkdir -p "$framework_dir/Headers" "$framework_dir/Modules"
  cp "$lib" "$framework_dir/nanopb"

  cp -R "$REF_SLICE/Headers/." "$framework_dir/Headers/"
  cp -R "$REF_SLICE/Modules/." "$framework_dir/Modules/"

  cat > "$framework_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>nanopb</string>
  <key>CFBundleIdentifier</key><string>org.cocoapods.nanopb</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>nanopb</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>2.30910.0</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform_name</string></array>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$min_os</string>
</dict>
</plist>
PLIST

  echo "Built: $framework_dir ($(du -h $framework_dir/nanopb | cut -f1))"
}

build_slice xros          xros-arm64           XROS         1.0
build_slice xrsimulator   xros-arm64-simulator XRSimulator  1.0

echo ""
echo "Merging xcframework"

MERGED="$OUT/nanopb.xcframework"
rm -rf "$MERGED"

xcodebuild -create-xcframework \
  -framework "$GOOGLE_NPB/ios-arm64/nanopb.framework" \
  -framework "$GOOGLE_NPB/ios-arm64_x86_64-simulator/nanopb.framework" \
  -framework "$GOOGLE_NPB/ios-arm64_x86_64-maccatalyst/nanopb.framework" \
  -framework "$GOOGLE_NPB/macos-arm64_x86_64/nanopb.framework" \
  -framework "$GOOGLE_NPB/tvos-arm64/nanopb.framework" \
  -framework "$GOOGLE_NPB/tvos-arm64_x86_64-simulator/nanopb.framework" \
  -framework "$GOOGLE_NPB/watchos-arm64_arm64_32/nanopb.framework" \
  -framework "$GOOGLE_NPB/watchos-arm64_x86_64-simulator/nanopb.framework" \
  -framework "$SLICES/xros-arm64/nanopb.framework" \
  -framework "$SLICES/xros-arm64-simulator/nanopb.framework" \
  -output "$MERGED"

ls "$MERGED"
