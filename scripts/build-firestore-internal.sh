#!/usr/bin/env bash
# Build FirebaseFirestoreInternal.xcframework with visionOS slices added.
#
# Strategy: SPM-build FirebaseFirestoreInternalWrapper for xros + xrsimulator
# (Release), libtool the resulting .o files into libFirebaseFirestoreInternal.a
# per slice, wrap as a static framework, then xcodebuild -create-xcframework
# merging Google's six pre-built slices (ios/macos/catalyst/tvos) with our two
# visionOS slices.
#
# After this script, Package.swift can use a single .binaryTarget(path:) for
# FirebaseFirestoreInternal — consumers get instant link on every platform,
# including visionOS and Xcode Cloud. No source compile.
#
# Idempotent. Re-run after bumping Firebase version (rebuilds visionOS slices).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_build_common.sh"

# _build_common sets CC="ccache clang" / CXX="ccache clang++" for CMake-based
# builds. xcodebuild parses those env vars as literal executable paths and
# fails with "unable to spawn process 'ccache clang'". Unset before xcodebuild.
unset CC CXX

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

OUT_ROOT="${REPO_ROOT}/build/artifacts/FirebaseFirestoreInternal"
SLICE_ROOT="${OUT_ROOT}-slices"
DD="${REPO_ROOT}/build/artifacts/FirebaseFirestoreInternal-dd"
GOOGLE_XCF="${REPO_ROOT}/build/downloads/Firebase-extracted/Firebase/FirebaseFirestore/FirebaseFirestoreInternal.xcframework"
PKG_BINARY="${REPO_ROOT}/Package.swift"
PKG_SOURCE="${REPO_ROOT}/scripts/Package-source-compile.swift"
PKG_BACKUP="${REPO_ROOT}/build/Package.swift.binary-mode-backup"

if [[ ! -d "${GOOGLE_XCF}" ]]; then
  echo "Missing Google's FirebaseFirestoreInternal.xcframework at ${GOOGLE_XCF}"
  echo "Extract Firebase.zip first."
  exit 1
fi

rm -rf "${OUT_ROOT}" "${SLICE_ROOT}"
mkdir -p "${OUT_ROOT}" "${SLICE_ROOT}"

# Swap Package.swift to source-compile mode for the duration of the build.
# Always restore via trap, even on error or interrupt.
cp "${PKG_BINARY}" "${PKG_BACKUP}"
cp "${PKG_SOURCE}" "${PKG_BINARY}"
restore_pkg() {
  if [[ -f "${PKG_BACKUP}" ]]; then
    cp "${PKG_BACKUP}" "${PKG_BINARY}"
    rm "${PKG_BACKUP}"
    echo "Restored binary-mode Package.swift"
  fi
}
trap restore_pkg EXIT INT TERM

echo "==== SPM-building FirebaseFirestoreInternalWrapper for visionOS slices ===="

# Pick the first available visionOS simulator with a matching SDK
VOS_SIM_ID="$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)
for rt,devs in d['devices'].items():
    if 'xrOS' in rt or 'visionOS' in rt:
        for dev in devs:
            if 'Apple Vision Pro' in dev['name']:
                print(dev['udid']); sys.exit(0)
")"
if [[ -z "${VOS_SIM_ID}" ]]; then
  echo "No Apple Vision Pro simulator found"
  exit 1
fi

xcodebuild -scheme firebase-firestore-xcframeworks \
  -destination 'generic/platform=visionOS' \
  -configuration Release \
  -derivedDataPath "${DD}" \
  build > /tmp/phase4p2-xros-build.log 2>&1 \
  || { echo "xros build failed — see /tmp/phase4p2-xros-build.log"; exit 1; }
echo "  xros (device) build OK"

xcodebuild -scheme firebase-firestore-xcframeworks \
  -destination "platform=visionOS Simulator,id=${VOS_SIM_ID}" \
  -configuration Release \
  -derivedDataPath "${DD}" \
  build > /tmp/phase4p2-xrsim-build.log 2>&1 \
  || { echo "xrsimulator build failed — see /tmp/phase4p2-xrsim-build.log"; exit 1; }
echo "  xrsimulator (sim) build OK"

# Slice the .o files we just produced into a static lib per visionOS slice,
# then wrap each in a FirebaseFirestoreInternal.framework directory.

build_slice() {
  local config="$1"      # Release-xros | Release-xrsimulator
  local slice_name="$2"  # xros-arm64 | xros-arm64-simulator

  local obj_dir="${DD}/Build/Intermediates.noindex/firebase-firestore-xcframeworks.build/${config}/FirebaseFirestoreInternalWrapper.build/Objects-normal/arm64"
  if [[ ! -d "${obj_dir}" ]]; then
    echo "Missing object dir: ${obj_dir}"
    exit 1
  fi

  local slice_dir="${SLICE_ROOT}/${slice_name}"
  local fw_dir="${slice_dir}/FirebaseFirestoreInternal.framework"
  mkdir -p "${fw_dir}/Headers" "${fw_dir}/Modules"

  # 1. libtool every .o into one static archive named after the framework.
  #    Apple's static-framework convention puts the archive at framework_root/<name>
  #    (no .a extension, no lib prefix).
  echo "  ${slice_name}: libtool $(ls "${obj_dir}"/*.o | wc -l | tr -d ' ') objects"
  libtool -static \
    -o "${fw_dir}/FirebaseFirestoreInternal" \
    "${obj_dir}"/*.o 2>&1 | grep -v "has no symbols" || true

  # 2. Strip debug info (DWARF). Unstripped the static lib is ~150 MB per slice;
  #    Google's iOS slice is 11 MB. `-S` drops debug-only symbols, preserves
  #    everything the linker needs.
  strip -S "${fw_dir}/FirebaseFirestoreInternal"

  # 3. Copy public headers from vendored Firestore source.
  cp "${REPO_ROOT}/Firestore/Source/Public/FirebaseFirestore/"*.h "${fw_dir}/Headers/"

  # 4. Generate umbrella header (matches Google's format — order doesn't matter).
  (
    echo "#ifdef __OBJC__"
    echo "#import <UIKit/UIKit.h>"
    echo "#else"
    echo "#ifndef FOUNDATION_EXPORT"
    echo "#if defined(__cplusplus)"
    echo "#define FOUNDATION_EXPORT extern \"C\""
    echo "#else"
    echo "#define FOUNDATION_EXPORT extern"
    echo "#endif"
    echo "#endif"
    echo "#endif"
    echo ""
    for h in "${REPO_ROOT}/Firestore/Source/Public/FirebaseFirestore/"*.h; do
      echo "#import \"$(basename "${h}")\""
    done
  ) > "${fw_dir}/Headers/FirebaseFirestoreInternal-umbrella.h"

  # 5. Modulemap matching Google's iOS slice. The hyphen-free module name
  #    `openssl_grpc` is enforced by scripts/normalize-openssl-grpc-modulemap.sh.
  cat > "${fw_dir}/Modules/module.modulemap" <<'EOF'
framework module FirebaseFirestoreInternal {
umbrella header "FirebaseFirestoreInternal-umbrella.h"
export *
module * { export * }
  link framework "openssl_grpc"
  link framework "grpc"
  link framework "grpcpp"
  link framework "Foundation"
  link framework "Security"
  link framework "SystemConfiguration"
  link framework "UIKit"
  link "c++"
  link "z"
}
EOF

  # 6. Info.plist. CFBundleSupportedPlatforms differs per slice.
  local supported_plats
  if [[ "${slice_name}" == "xros-arm64" ]]; then
    supported_plats="XROS"
  else
    supported_plats="XRSimulator"
  fi
  cat > "${fw_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>FirebaseFirestoreInternal</string>
    <key>CFBundleIdentifier</key><string>org.cocoapods.FirebaseFirestoreInternal</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>FirebaseFirestoreInternal</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>11.15.0</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleSupportedPlatforms</key><array><string>${supported_plats}</string></array>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>1.0</string>
</dict>
</plist>
EOF

  echo "  ${slice_name}: framework built ($(du -sh "${fw_dir}/FirebaseFirestoreInternal" | awk '{print $1}'))"
}

echo "==== Wrapping objects as framework slices ===="
build_slice "Release-xros" "xros-arm64"
build_slice "Release-xrsimulator" "xros-arm64-simulator"

echo "==== Merging with Google's six slices via xcodebuild -create-xcframework ===="

GOOGLE_SLICES=(
  "ios-arm64"
  "ios-arm64_x86_64-simulator"
  "ios-arm64_x86_64-maccatalyst"
  "macos-arm64_x86_64"
  "tvos-arm64"
  "tvos-arm64_x86_64-simulator"
)

cmd_args=()
for s in "${GOOGLE_SLICES[@]}"; do
  cmd_args+=(-framework "${GOOGLE_XCF}/${s}/FirebaseFirestoreInternal.framework")
done
cmd_args+=(-framework "${SLICE_ROOT}/xros-arm64/FirebaseFirestoreInternal.framework")
cmd_args+=(-framework "${SLICE_ROOT}/xros-arm64-simulator/FirebaseFirestoreInternal.framework")

rm -rf "${OUT_ROOT}/FirebaseFirestoreInternal.xcframework"
xcodebuild -create-xcframework \
  "${cmd_args[@]}" \
  -output "${OUT_ROOT}/FirebaseFirestoreInternal.xcframework"

echo "==== Done ===="
ls "${OUT_ROOT}/FirebaseFirestoreInternal.xcframework"
