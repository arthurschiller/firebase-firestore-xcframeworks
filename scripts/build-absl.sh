#!/usr/bin/env bash
# Build absl.xcframework with added visionOS slices.
#
# Strategy:
#   1. CMake-build abseil-cpp for xros-arm64 + xrsimulator-arm64
#   2. Combine all libabsl_*.a per slice into single absl binary (libtool -static)
#   3. Wrap each into absl.framework, copying Headers/ + Modules/ + Info.plist
#      from Google's existing iOS slice (same source commit → identical headers)
#   4. xcodebuild -create-xcframework merging Google's 6 slices + our 2
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_build_common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/build/sources/abseil-cpp"
GOOGLE_ABSL="$REPO_ROOT/build/downloads/Firebase-extracted/Firebase/FirebaseFirestore/absl.xcframework"
OUT="$REPO_ROOT/build/artifacts/absl"
SLICES="$REPO_ROOT/build/artifacts/absl-slices"

if [ ! -d "$SRC" ]; then echo "ERROR: abseil source not at $SRC"; exit 1; fi
if [ ! -d "$GOOGLE_ABSL" ]; then echo "ERROR: Google absl.xcframework not at $GOOGLE_ABSL"; exit 1; fi

# Force absl's stdlib-interop options to "distinct class" mode (=0) instead
# of auto-detect (=2). Auto-detect picks std:: aliases when compiled with
# C++17, which produces different mangled symbol names than gRPC's bundled
# absl build (which compiles with a different effective C++ standard via
# CMake submodule defaults). The ABI mismatch breaks linking: grpc.framework
# references e.g. absl::Base64Escape(absl::string_view) but our absl.framework
# would define absl::Base64Escape(std::string_view). Forcing all options to 0
# makes the ABI deterministic and matches Google's own iOS/macOS/tvOS slices.
sed -i.bak 's/^#define ABSL_OPTION_USE_STD_\([A-Z_]*\) 2$/#define ABSL_OPTION_USE_STD_\1 0/' \
  "$SRC/absl/base/options.h"

rm -rf "$OUT" "$SLICES"
mkdir -p "$OUT" "$SLICES"

# Reference slice for headers / module map / Info.plist template
REF_SLICE="$GOOGLE_ABSL/ios-arm64/absl.framework"

build_slice() {
  local sdk="$1"        # xros | xrsimulator
  local slice_name="$2" # xros-arm64 | xros-arm64-simulator (xcodebuild naming convention)
  local platform_name="$3" # XROS | XRSimulator (Info.plist CFBundleSupportedPlatforms entry)
  local min_os="$4"     # e.g. 1.0

  local build_dir="$REPO_ROOT/build/artifacts/absl-build-$sdk"
  local framework_dir="$SLICES/$slice_name/absl.framework"

  echo ""
  echo "=========================================="
  echo "Building abseil for $sdk (arm64)"
  echo "=========================================="

  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  # CMake configure
  cmake -S "$SRC" -B "$build_dir" \
    -G "Unix Makefiles" \
    "${CMAKE_CCACHE_ARGS[@]}" \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_os" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DABSL_BUILD_TESTING=OFF \
    -DABSL_PROPAGATE_CXX_STD=ON \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_STANDARD_REQUIRED=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON

  # Build
  cmake --build "$build_dir" -j$PARALLEL_JOBS

  # Collect all libabsl_*.a from build tree. Avoid `mapfile` so the script
  # runs under macOS's stock bash 3.2 (which CI uses).
  libs=()
  while IFS= read -r f; do libs+=("$f"); done < <(find "$build_dir" -name "libabsl_*.a" -type f)
  if [ "${#libs[@]}" -eq 0 ]; then
    echo "ERROR: no libabsl_*.a produced under $build_dir"
    exit 1
  fi
  echo "Found ${#libs[@]} abseil sublibs; combining..."

  # Wrap into framework dir
  mkdir -p "$framework_dir/Headers" "$framework_dir/Modules"

  # Combine all .a into single static binary named "absl"
  libtool -static -o "$framework_dir/absl" "${libs[@]}"

  # Copy headers and module map from Google's iOS slice (same source → identical headers)
  cp -R "$REF_SLICE/Headers/." "$framework_dir/Headers/"
  cp -R "$REF_SLICE/Modules/." "$framework_dir/Modules/"

  # Apply the same options.h patch to the shipped headers so any consumer code
  # that compiles against absl headers picks up the same ABI as our binary.
  if [ -f "$framework_dir/Headers/base/options.h" ]; then
    sed -i.bak 's/^#define ABSL_OPTION_USE_STD_\([A-Z_]*\) 2$/#define ABSL_OPTION_USE_STD_\1 0/' \
      "$framework_dir/Headers/base/options.h"
    rm -f "$framework_dir/Headers/base/options.h.bak"
  fi

  # Generate Info.plist with correct platform metadata
  cat > "$framework_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>absl</string>
  <key>CFBundleIdentifier</key><string>org.cocoapods.absl</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>absl</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.20240722.0</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform_name</string></array>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$min_os</string>
</dict>
</plist>
PLIST

  echo "Built slice: $framework_dir"
  echo "  binary arch: $(lipo -info "$framework_dir/absl" 2>&1)"
  echo "  binary size: $(du -h "$framework_dir/absl" | cut -f1)"
}

build_slice xros          xros-arm64           XROS         1.0
build_slice xrsimulator   xros-arm64-simulator XRSimulator  1.0

# Merge with Google's 6 existing slices
echo ""
echo "=========================================="
echo "Merging xcframework"
echo "=========================================="

MERGED="$OUT/absl.xcframework"
rm -rf "$MERGED"

xcodebuild -create-xcframework \
  -framework "$GOOGLE_ABSL/ios-arm64/absl.framework" \
  -framework "$GOOGLE_ABSL/ios-arm64_x86_64-simulator/absl.framework" \
  -framework "$GOOGLE_ABSL/ios-arm64_x86_64-maccatalyst/absl.framework" \
  -framework "$GOOGLE_ABSL/macos-arm64_x86_64/absl.framework" \
  -framework "$GOOGLE_ABSL/tvos-arm64/absl.framework" \
  -framework "$GOOGLE_ABSL/tvos-arm64_x86_64-simulator/absl.framework" \
  -framework "$SLICES/xros-arm64/absl.framework" \
  -framework "$SLICES/xros-arm64-simulator/absl.framework" \
  -output "$MERGED"

echo ""
echo "=== Final xcframework ==="
ls "$MERGED"
plutil -p "$MERGED/Info.plist" | grep -E "LibraryIdentifier|SupportedPlatform" | head -30
