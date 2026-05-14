#!/usr/bin/env bash
# Build leveldb.xcframework with added visionOS slices.
# Source: firebase/leveldb @ 1.22.5 (matching Firebase 11.15.0's Package.resolved).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_build_common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/build/sources/leveldb"
GOOGLE_LDB="$REPO_ROOT/build/downloads/Firebase-extracted/Firebase/FirebaseFirestore/leveldb.xcframework"
OUT="$REPO_ROOT/build/artifacts/leveldb"
SLICES="$REPO_ROOT/build/artifacts/leveldb-slices"

for p in "$SRC" "$GOOGLE_LDB"; do
  if [ ! -e "$p" ]; then echo "ERROR: missing $p"; exit 1; fi
done

rm -rf "$OUT" "$SLICES"
mkdir -p "$OUT" "$SLICES"

REF_SLICE="$GOOGLE_LDB/ios-arm64/leveldb.framework"

build_slice() {
  local sdk="$1"
  local slice_name="$2"
  local platform_name="$3"
  local min_os="$4"

  local build_dir="$REPO_ROOT/build/artifacts/leveldb-build-$sdk"
  local framework_dir="$SLICES/$slice_name/leveldb.framework"

  echo ""
  echo "=========================================="
  echo "Building leveldb for $sdk (arm64)"
  echo "=========================================="

  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  cmake -S "$SRC" -B "$build_dir" \
    -G "Unix Makefiles" \
    "${CMAKE_CCACHE_ARGS[@]}" \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_os" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DLEVELDB_BUILD_TESTS=OFF \
    -DLEVELDB_BUILD_BENCHMARKS=OFF \
    -DLEVELDB_INSTALL=OFF \
    -DHAVE_CRC32C=OFF \
    -DHAVE_SNAPPY=OFF \
    -DHAVE_TCMALLOC=OFF \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_STANDARD_REQUIRED=ON

  cmake --build "$build_dir" --target leveldb -j$PARALLEL_JOBS

  local ldb_lib="$build_dir/libleveldb.a"
  if [ ! -f "$ldb_lib" ]; then
    echo "ERROR: libleveldb.a not found"; find "$build_dir" -name "libleveldb.a"; exit 1
  fi

  mkdir -p "$framework_dir/Headers" "$framework_dir/Modules"
  cp "$ldb_lib" "$framework_dir/leveldb"

  cp -R "$REF_SLICE/Headers/." "$framework_dir/Headers/"
  cp -R "$REF_SLICE/Modules/." "$framework_dir/Modules/"

  cat > "$framework_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>leveldb</string>
  <key>CFBundleIdentifier</key><string>org.cocoapods.leveldb-library</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>leveldb</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.22.5</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform_name</string></array>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$min_os</string>
</dict>
</plist>
PLIST

  echo "Built: $framework_dir ($(du -h $framework_dir/leveldb | cut -f1))"
}

build_slice xros          xros-arm64           XROS         1.0
build_slice xrsimulator   xros-arm64-simulator XRSimulator  1.0

echo ""
echo "=========================================="
echo "Merging xcframework"
echo "=========================================="

MERGED="$OUT/leveldb.xcframework"
rm -rf "$MERGED"

xcodebuild -create-xcframework \
  -framework "$GOOGLE_LDB/ios-arm64/leveldb.framework" \
  -framework "$GOOGLE_LDB/ios-arm64_x86_64-simulator/leveldb.framework" \
  -framework "$GOOGLE_LDB/ios-arm64_x86_64-maccatalyst/leveldb.framework" \
  -framework "$GOOGLE_LDB/macos-arm64_x86_64/leveldb.framework" \
  -framework "$GOOGLE_LDB/tvos-arm64/leveldb.framework" \
  -framework "$GOOGLE_LDB/tvos-arm64_x86_64-simulator/leveldb.framework" \
  -framework "$SLICES/xros-arm64/leveldb.framework" \
  -framework "$SLICES/xros-arm64-simulator/leveldb.framework" \
  -output "$MERGED"

echo ""
ls "$MERGED"
