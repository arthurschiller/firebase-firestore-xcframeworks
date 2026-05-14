#!/usr/bin/env bash
# Build openssl_grpc.xcframework with added visionOS slices.
#
# Strategy:
#   1. Decode boringssl_prefix_symbols.h from gRPC's BoringSSL-GRPC.podspec
#      (embedded as base64-gzip). 3609 #defines map SSL_foo → GRPC_SSL_foo —
#      ABI-matches Google's iOS slice exactly.
#   2. CMake-build BoringSSL for xros + xrsimulator with
#         -DOPENSSL_NO_ASM -DBORINGSSL_PREFIX=GRPC
#   3. Combine libssl.a + libcrypto.a → single openssl_grpc binary
#   4. Wrap into openssl_grpc.framework, reusing Google's Headers/ + Modules/
#   5. Merge with Google's existing openssl_grpc.xcframework
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRPC_SRC="$REPO_ROOT/build/sources/grpc"
BSL_SRC="$GRPC_SRC/third_party/boringssl-with-bazel"
PODSPEC="$GRPC_SRC/src/objective-c/BoringSSL-GRPC.podspec"
GOOGLE_SSL="$REPO_ROOT/build/downloads/Firebase-extracted/Firebase/FirebaseFirestore/openssl_grpc.xcframework"
OUT="$REPO_ROOT/build/artifacts/openssl_grpc"
SLICES="$REPO_ROOT/build/artifacts/openssl_grpc-slices"

for p in "$BSL_SRC" "$PODSPEC" "$GOOGLE_SSL"; do
  if [ ! -e "$p" ]; then echo "ERROR: missing $p"; exit 1; fi
done

rm -rf "$OUT" "$SLICES"
mkdir -p "$OUT" "$SLICES"

REF_SLICE="$GOOGLE_SSL/ios-arm64/openssl_grpc.framework"

# 1. Decode prefix-symbols header (base64-gzip block in podspec, lines 176-698)
#    and place where BoringSSL's `#include <boringssl_prefix_symbols.h>` finds it.
PREFIX_H="$BSL_SRC/src/include/boringssl_prefix_symbols.h"
if [ ! -s "$PREFIX_H" ]; then
  echo "Decoding boringssl_prefix_symbols.h from podspec..."
  sed -n '176,698p' "$PODSPEC" | sed 's/^      //' | base64 --decode | gunzip > "$PREFIX_H"
fi
echo "Prefix header: $(grep -c '^#define' $PREFIX_H) defines"

build_slice() {
  local sdk="$1"          # xros | xrsimulator
  local slice_name="$2"   # xros-arm64 | xros-arm64-simulator
  local platform_name="$3" # XROS | XRSimulator
  local min_os="$4"

  local build_dir="$REPO_ROOT/build/artifacts/openssl_grpc-build-$sdk"
  local framework_dir="$SLICES/$slice_name/openssl_grpc.framework"

  echo ""
  echo "=========================================="
  echo "Building BoringSSL for $sdk (arm64)"
  echo "=========================================="

  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  cmake -S "$BSL_SRC" -B "$build_dir" \
    -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=visionOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_os" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DOPENSSL_NO_ASM=1 \
    -DCMAKE_C_FLAGS="-DOPENSSL_NO_ASM -DBORINGSSL_PREFIX=GRPC -fvisibility=hidden -fno-common" \
    -DCMAKE_CXX_FLAGS="-DOPENSSL_NO_ASM -DBORINGSSL_PREFIX=GRPC -fvisibility=hidden -fno-common -fno-exceptions -fno-rtti"

  cmake --build "$build_dir" --target ssl crypto -j

  local ssl_lib="$build_dir/libssl.a"
  local crypto_lib="$build_dir/libcrypto.a"
  if [ ! -f "$ssl_lib" ] || [ ! -f "$crypto_lib" ]; then
    echo "ERROR: missing libssl.a or libcrypto.a"
    find "$build_dir" -name "libssl.a" -o -name "libcrypto.a"
    exit 1
  fi

  mkdir -p "$framework_dir/Headers" "$framework_dir/Modules" "$framework_dir/PrivateHeaders"

  libtool -static -o "$framework_dir/openssl_grpc" "$ssl_lib" "$crypto_lib"

  # Headers + module map: copy Google's iOS slice (same source commit → same headers)
  cp -R "$REF_SLICE/Headers/." "$framework_dir/Headers/"
  cp -R "$REF_SLICE/Modules/." "$framework_dir/Modules/"
  cp -R "$REF_SLICE/PrivateHeaders/." "$framework_dir/PrivateHeaders/"

  cat > "$framework_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>openssl_grpc</string>
  <key>CFBundleIdentifier</key><string>org.cocoapods.openssl-grpc</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>openssl_grpc</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.0.37</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform_name</string></array>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$min_os</string>
</dict>
</plist>
PLIST

  echo "Built: $framework_dir"
  echo "  arch: $(lipo -info $framework_dir/openssl_grpc 2>&1)"
  echo "  size: $(du -h $framework_dir/openssl_grpc | cut -f1)"
  echo "  GRPC_ symbols: $(nm -gU $framework_dir/openssl_grpc 2>&1 | grep -c _GRPC_)"
}

build_slice xros          xros-arm64           XROS         1.0
build_slice xrsimulator   xros-arm64-simulator XRSimulator  1.0

echo ""
echo "=========================================="
echo "Merging xcframework"
echo "=========================================="

MERGED="$OUT/openssl_grpc.xcframework"
rm -rf "$MERGED"

xcodebuild -create-xcframework \
  -framework "$GOOGLE_SSL/ios-arm64/openssl_grpc.framework" \
  -framework "$GOOGLE_SSL/ios-arm64_x86_64-simulator/openssl_grpc.framework" \
  -framework "$GOOGLE_SSL/ios-arm64_x86_64-maccatalyst/openssl_grpc.framework" \
  -framework "$GOOGLE_SSL/macos-arm64_x86_64/openssl_grpc.framework" \
  -framework "$GOOGLE_SSL/tvos-arm64/openssl_grpc.framework" \
  -framework "$GOOGLE_SSL/tvos-arm64_x86_64-simulator/openssl_grpc.framework" \
  -framework "$SLICES/xros-arm64/openssl_grpc.framework" \
  -framework "$SLICES/xros-arm64-simulator/openssl_grpc.framework" \
  -output "$MERGED"

echo ""
ls "$MERGED"

# Verify ABI parity: our visionOS slice's GRPC_ symbol set must match
# Google's iOS slice exactly. Drift here means gRPC + Firestore link will
# fail on visionOS. Fail the build loud so a future Firebase bump doesn't
# ship a broken xcframework silently.
echo ""
echo "=========================================="
echo "Verifying GRPC_ symbol parity vs Google iOS"
echo "=========================================="

OURS_BIN="$SLICES/xros-arm64/openssl_grpc.framework/openssl_grpc"
GOOGLE_BIN="$GOOGLE_SSL/ios-arm64/openssl_grpc.framework/openssl_grpc"

nm -gU "$OURS_BIN"   2>/dev/null | grep " _GRPC_" | awk '{print $NF}' | sort -u > /tmp/abi_ours.txt
nm -gU "$GOOGLE_BIN" 2>/dev/null | grep " _GRPC_" | awk '{print $NF}' | sort -u > /tmp/abi_google.txt

OURS_N=$(wc -l < /tmp/abi_ours.txt)
GOOGLE_N=$(wc -l < /tmp/abi_google.txt)
MISSING=$(comm -13 /tmp/abi_ours.txt /tmp/abi_google.txt | wc -l | tr -d ' ')
EXTRA=$(comm -23 /tmp/abi_ours.txt /tmp/abi_google.txt | wc -l | tr -d ' ')

echo "Ours (xros-arm64):  $OURS_N GRPC_ symbols"
echo "Google (ios-arm64): $GOOGLE_N GRPC_ symbols"
echo "Missing in ours:    $MISSING"
echo "Extra in ours:      $EXTRA"

if [ "$MISSING" -ne 0 ] || [ "$EXTRA" -ne 0 ]; then
  echo ""
  echo "FAIL: ABI drift detected vs Google's iOS slice."
  echo ""
  echo "Sample missing in ours (gRPC/Firestore would fail to link these):"
  comm -13 /tmp/abi_ours.txt /tmp/abi_google.txt | head -5
  echo ""
  echo "Sample extra in ours (less critical but suggests config drift):"
  comm -23 /tmp/abi_ours.txt /tmp/abi_google.txt | head -5
  exit 1
fi
echo "PASS: symbol-identical to Google's iOS slice."
