#!/usr/bin/env bash
# Build FirebaseFirestore.xcframework (the Swift wrapper) with visionOS slices.
#
# Strategy: same as build-firestore-internal.sh but for the Firestore Swift
# wrapper code (Firestore/Swift/Source/*.swift). xcodebuild archive each
# visionOS platform, then xcodebuild -create-xcframework to merge with
# Google's six untouched iOS/macOS/Catalyst/tvOS slices from Firebase.zip.
#
# After this script the FirebaseFirestore.xcframework is shippable as a
# binaryTarget — consumers `import FirebaseFirestore` resolves to the
# framework's own modulemap, sidestepping the SPM target-name collision with
# upstream firebase-ios-sdk's source-target `FirebaseFirestore`.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_build_common.sh"
unset CC CXX  # _build_common sets ccache wrappers that xcodebuild rejects

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

OUT_ROOT="${REPO_ROOT}/build/artifacts/FirebaseFirestore"
SLICE_ROOT="${OUT_ROOT}-slices"
DD="${REPO_ROOT}/build/artifacts/FirebaseFirestore-dd"
GOOGLE_XCF="${REPO_ROOT}/build/downloads/Firebase-extracted-full/Firebase/FirebaseFirestore/FirebaseFirestore.xcframework"
PKG_BINARY="${REPO_ROOT}/Package.swift"
PKG_SOURCE="${REPO_ROOT}/scripts/Package-source-compile.swift"
PKG_BACKUP="${REPO_ROOT}/build/Package.swift.binary-mode-backup"

if [[ ! -d "${GOOGLE_XCF}" ]]; then
  echo "Missing Google's FirebaseFirestore.xcframework at ${GOOGLE_XCF}"
  echo "Extract Firebase.zip first."
  exit 1
fi

rm -rf "${OUT_ROOT}" "${SLICE_ROOT}"
mkdir -p "${OUT_ROOT}" "${SLICE_ROOT}"

# Swap Package.swift to source-compile mode for the duration of the build.
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

echo "==== Archiving FirebaseFirestore (Swift wrapper) for visionOS slices ===="

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

# BUILD_LIBRARY_FOR_DISTRIBUTION enables library evolution, required to ship
# Swift modules as binaries consumed across builds (.swiftinterface emission).
SHARED_FLAGS=(
  -configuration Release
  -derivedDataPath "${DD}"
  SKIP_INSTALL=NO
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES
  OTHER_SWIFT_FLAGS='-no-verify-emitted-module-interface'
)

xcodebuild archive \
  -scheme FirebaseFirestore \
  -destination 'generic/platform=visionOS' \
  -archivePath "${OUT_ROOT}/xros-arm64.xcarchive" \
  "${SHARED_FLAGS[@]}" > /tmp/build-firestore-swift-xros.log 2>&1 \
  || { echo "xros archive failed — /tmp/build-firestore-swift-xros.log"; tail -30 /tmp/build-firestore-swift-xros.log; exit 1; }
echo "  xros (device) archive OK"

xcodebuild archive \
  -scheme FirebaseFirestore \
  -destination "platform=visionOS Simulator,id=${VOS_SIM_ID}" \
  -archivePath "${OUT_ROOT}/xros-arm64-simulator.xcarchive" \
  "${SHARED_FLAGS[@]}" > /tmp/build-firestore-swift-xrsim.log 2>&1 \
  || { echo "xrsimulator archive failed — /tmp/build-firestore-swift-xrsim.log"; tail -30 /tmp/build-firestore-swift-xrsim.log; exit 1; }
echo "  xrsimulator (sim) archive OK"

# xcarchive stashes built frameworks under Products/usr/local/lib (or similar
# depending on Xcode). Locate the FirebaseFirestore.framework in each archive.
locate_framework() {
  local archive="$1"
  find "${archive}/Products" -name "FirebaseFirestore.framework" -type d | head -1
}

XROS_FW="$(locate_framework "${OUT_ROOT}/xros-arm64.xcarchive")"
XRSIM_FW="$(locate_framework "${OUT_ROOT}/xros-arm64-simulator.xcarchive")"

if [[ -z "${XROS_FW}" || -z "${XRSIM_FW}" ]]; then
  echo "Couldn't locate FirebaseFirestore.framework in archives:"
  echo "  xros: ${XROS_FW}"
  echo "  xrsim: ${XRSIM_FW}"
  echo "Archive contents:"
  find "${OUT_ROOT}/xros-arm64.xcarchive" -name "*.framework" | head
  exit 1
fi

echo "  xros framework: $(du -sh "${XROS_FW}" | awk '{print $1}')"
echo "  xrsim framework: $(du -sh "${XRSIM_FW}" | awk '{print $1}')"

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
  cmd_args+=(-framework "${GOOGLE_XCF}/${s}/FirebaseFirestore.framework")
done
cmd_args+=(-framework "${XROS_FW}")
cmd_args+=(-framework "${XRSIM_FW}")

rm -rf "${OUT_ROOT}/FirebaseFirestore.xcframework"
xcodebuild -create-xcframework \
  "${cmd_args[@]}" \
  -output "${OUT_ROOT}/FirebaseFirestore.xcframework"

echo "==== Done ===="
ls "${OUT_ROOT}/FirebaseFirestore.xcframework"
