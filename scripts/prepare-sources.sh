#!/usr/bin/env bash
# Prepare source trees + Google's Firebase.zip for a given Firebase version.
# Idempotent: if a source tree is already at the right tag, leaves it alone.
#
# Usage: scripts/prepare-sources.sh <firebase_version>
# Example: scripts/prepare-sources.sh 11.15.0
#
# What it produces:
#   build/sources/firebase-ios-sdk/   (clone at tag <firebase_version>)
#   build/sources/abseil-cpp/         (clone at detected absl tag)
#   build/sources/grpc/               (clone at detected gRPC tag + submodules)
#   build/sources/leveldb/            (clone at detected leveldb tag)
#   build/sources/nanopb/             (clone at detected nanopb tag)
#   build/downloads/Firebase.zip      (Google's binary distribution)
#   build/downloads/Firebase-extracted/ (unzipped distribution)
#   Firestore/, FirebaseCore/, CoreOnly/, FirebaseFirestoreInternal/  (vendored from firebase-ios-sdk + patched)

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <firebase_version>"
  exit 2
fi
FIREBASE_VERSION="$1"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SOURCES="$REPO_ROOT/build/sources"
DOWNLOADS="$REPO_ROOT/build/downloads"
mkdir -p "$SOURCES" "$DOWNLOADS"

# -----------------------------------------------------------------------------
# 1. firebase-ios-sdk: clone or fetch+checkout at the requested tag
# -----------------------------------------------------------------------------
FBI="$SOURCES/firebase-ios-sdk"
if [[ ! -d "$FBI/.git" ]]; then
  echo "==> Cloning firebase-ios-sdk @ $FIREBASE_VERSION"
  # Wipe any non-git directory (e.g. extracted tarball) so we get a proper clone.
  rm -rf "$FBI"
  git clone --depth=1 --branch "$FIREBASE_VERSION" \
    https://github.com/firebase/firebase-ios-sdk.git "$FBI"
else
  current="$(git -C "$FBI" describe --tags --exact-match 2>/dev/null || echo "unknown")"
  if [[ "$current" != "$FIREBASE_VERSION" ]]; then
    echo "==> Fetching firebase-ios-sdk @ $FIREBASE_VERSION (currently $current)"
    git -C "$FBI" fetch --depth=1 origin "refs/tags/$FIREBASE_VERSION:refs/tags/$FIREBASE_VERSION"
    git -C "$FBI" -c advice.detachedHead=false checkout "$FIREBASE_VERSION"
  else
    echo "==> firebase-ios-sdk already at $FIREBASE_VERSION"
  fi
fi

# -----------------------------------------------------------------------------
# 2. Download + extract Google's Firebase.zip (binary distribution)
# -----------------------------------------------------------------------------
FB_ZIP="$DOWNLOADS/Firebase-$FIREBASE_VERSION.zip"
FB_EXTRACT="$DOWNLOADS/Firebase-extracted"
if [[ ! -f "$FB_ZIP" ]]; then
  echo "==> Downloading Firebase.zip @ $FIREBASE_VERSION"
  curl -fL --progress-bar \
    "https://github.com/firebase/firebase-ios-sdk/releases/download/$FIREBASE_VERSION/Firebase.zip" \
    -o "$FB_ZIP"
fi
echo "==> Extracting Firebase.zip"
rm -rf "$FB_EXTRACT"
mkdir -p "$FB_EXTRACT"
unzip -q "$FB_ZIP" -d "$FB_EXTRACT"

# Firebase 11.x's Firebase.zip is a META-zip: it contains build_logs/, carthage/,
# and a versioned subdir holding the actual binary distribution as a nested zip
# (e.g. 11_15_0/Firebase-11.15.0-latest.zip). Extract that nested zip.
inner_zip="$(find "$FB_EXTRACT" -name "Firebase-*-latest.zip" -type f | head -1)"
if [[ -n "$inner_zip" ]]; then
  echo "    extracting inner $(basename "$inner_zip")"
  unzip -q "$inner_zip" -d "$(dirname "$inner_zip")"
fi

# Now locate Firebase/ at any depth and move it to where build scripts expect it.
if [[ ! -d "$FB_EXTRACT/Firebase" ]]; then
  firebase_dir="$(find "$FB_EXTRACT" -name "Firebase" -type d -not -path "*/__MACOSX/*" | head -1)"
  if [[ -n "$firebase_dir" ]]; then
    mv "$firebase_dir" "$FB_EXTRACT/Firebase"
  else
    echo "ERROR: Firebase/ directory not found anywhere under $FB_EXTRACT"
    exit 1
  fi
fi

# Drop META-zip cruft we don't need.
rm -rf "$FB_EXTRACT/__MACOSX" "$FB_EXTRACT/build_logs" "$FB_EXTRACT/carthage"
find "$FB_EXTRACT" -mindepth 1 -maxdepth 1 -type d -name "[0-9]*_[0-9]*_[0-9]*" -exec rm -rf {} \;

# -----------------------------------------------------------------------------
# 3. Detect dep versions from the extracted xcframework Info.plists
# -----------------------------------------------------------------------------
get_xcfw_version() {
  local plist="$1/ios-arm64/$(basename "$1" .xcframework).framework/Info.plist"
  if [[ ! -f "$plist" ]]; then
    # macOS-style framework path
    plist="$1/macos-arm64_x86_64/$(basename "$1" .xcframework).framework/Versions/A/Resources/Info.plist"
  fi
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null
}

FIRESTORE_XCF="$FB_EXTRACT/Firebase/FirebaseFirestore"
absl_raw="$(get_xcfw_version "$FIRESTORE_XCF/absl.xcframework")"        # e.g. 1.20240722.0
grpc_raw="$(get_xcfw_version "$FIRESTORE_XCF/grpc.xcframework")"        # e.g. 1.69.0
leveldb_raw="$(get_xcfw_version "$FIRESTORE_XCF/leveldb.xcframework")"  # e.g. 1.22.6

# Strip the leading "1." that Firebase prepends for absl (CocoaPods convention)
# to match upstream abseil-cpp's git tag scheme.
ABSL_TAG="${absl_raw#1.}"
GRPC_TAG="v${grpc_raw}"
LEVELDB_TAG="${leveldb_raw}"

echo "==> Detected dep versions:"
echo "    abseil-cpp: $ABSL_TAG"
echo "    grpc:       $GRPC_TAG"
echo "    leveldb:    $LEVELDB_TAG"
# nanopb is consumed as an SPM source package (firebase/nanopb), not built
# as a binary in our overlay, so we don't clone its source here.

# -----------------------------------------------------------------------------
# 4. Source repos: clone or checkout at the detected tags
# -----------------------------------------------------------------------------
sync_source() {
  local dir="$1" url="$2" tag="$3"
  if [[ ! -d "$dir/.git" ]]; then
    echo "==> Cloning $(basename "$dir") @ $tag"
    rm -rf "$dir"
    if ! git clone --depth=1 --branch "$tag" "$url" "$dir" 2>&1; then
      echo "WARN: tag $tag not found on remote; falling back to default branch"
      echo "      (Firebase sometimes bumps the bundle version of an xcframework"
      echo "      without creating a matching source tag — verify manually if"
      echo "      build output differs from upstream.)"
      git clone --depth=1 "$url" "$dir"
    fi
  else
    local current
    current="$(git -C "$dir" describe --tags --exact-match 2>/dev/null || echo "unknown")"
    if [[ "$current" != "$tag" ]]; then
      echo "==> Fetching $(basename "$dir") @ $tag (currently $current)"
      if git -C "$dir" fetch --depth=1 origin "refs/tags/$tag:refs/tags/$tag" 2>&1; then
        git -C "$dir" -c advice.detachedHead=false checkout "$tag"
        git -C "$dir" clean -fdx
      else
        echo "WARN: tag $tag not found on remote — keeping $(basename "$dir") at $current"
        echo "      (Firebase sometimes bumps the bundle version of an xcframework"
        echo "      without creating a matching source tag.)"
      fi
    else
      echo "==> $(basename "$dir") already at $tag"
    fi
  fi
}

sync_source "$SOURCES/abseil-cpp" https://github.com/abseil/abseil-cpp.git "$ABSL_TAG"
sync_source "$SOURCES/grpc"       https://github.com/grpc/grpc.git          "$GRPC_TAG"
sync_source "$SOURCES/leveldb"    https://github.com/firebase/leveldb.git   "$LEVELDB_TAG"

# gRPC pulls boringssl + its own bundled abseil-cpp as git submodules; the
# build scripts need both. `--depth=1` keeps fetches small.
echo "==> Initializing gRPC submodules"
git -C "$SOURCES/grpc" submodule update --init --recursive --depth 1

# -----------------------------------------------------------------------------
# 5. Patch abseil-cpp options.h to force the distinct-class ABI
# -----------------------------------------------------------------------------
# Auto-detect (=2) chooses std:: aliases under C++17 and produces mangled
# symbols that don't match gRPC's bundled-absl build (which auto-detects to
# distinct-class). Forcing 0 makes the ABI deterministic. Matches Google's
# iOS/macOS/tvOS slices. Patch BOTH the standalone tree and gRPC's bundled
# abseil-cpp submodule so a future toolchain change can't desync them.
patch_absl_options() {
  local h="$1"
  if [[ -f "$h" ]] && grep -q "^#define ABSL_OPTION_USE_STD_STRING_VIEW 2$" "$h"; then
    echo "    patching $(echo "$h" | sed "s|$REPO_ROOT/||")"
    sed -i.bak 's/^#define ABSL_OPTION_USE_STD_\([A-Z_]*\) 2$/#define ABSL_OPTION_USE_STD_\1 0/' "$h"
    rm -f "$h.bak"
  fi
}
echo "==> Patching abseil-cpp options.h (force ABSL_OPTION_USE_STD_*=0)"
patch_absl_options "$SOURCES/abseil-cpp/absl/base/options.h"
patch_absl_options "$SOURCES/grpc/third_party/abseil-cpp/absl/base/options.h"

# -----------------------------------------------------------------------------
# 6. Sync vendored Firestore / FirebaseCore / CoreOnly / FirebaseFirestoreInternal
#    from firebase-ios-sdk into the repo root, where Package-source-compile.swift
#    expects them.
# -----------------------------------------------------------------------------
echo "==> Syncing vendored source dirs from firebase-ios-sdk"
# Exclude only things we deliberately don't vendor (tests, fuzzers, examples,
# top-level docs, CMake glue). .DS_Store is excluded from the source side but
# NOT from --delete, so any stray local .DS_Stores get cleared.
RSYNC_EXCLUDES=(
  --exclude='Tests/'
  --exclude='Example/'
  --exclude='fuzzing/'
  --exclude='CHANGELOG.md'
  --exclude='NOTICES'
  --exclude='README.md'
  --exclude='CMakeLists.txt'
)

for dir in Firestore FirebaseCore CoreOnly FirebaseFirestoreInternal; do
  if [[ -d "$FBI/$dir" ]]; then
    rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$FBI/$dir/" "$REPO_ROOT/$dir/"
    echo "    synced $dir/"
  else
    echo "WARN: $FBI/$dir not found in upstream — skipping"
  fi
done

# -----------------------------------------------------------------------------
# 7. Re-apply our Firestore Swift Source patches (idempotent)
# -----------------------------------------------------------------------------
bash "$REPO_ROOT/scripts/apply-patches.sh"

# -----------------------------------------------------------------------------
# 8. Bump version strings hardcoded in build scripts and source-compile manifest
# -----------------------------------------------------------------------------
echo "==> Updating version pins"
sed -i.bak "s/^let firebaseVersion = \".*\"/let firebaseVersion = \"$FIREBASE_VERSION\"/" \
  "$REPO_ROOT/scripts/Package-source-compile.swift"
rm -f "$REPO_ROOT/scripts/Package-source-compile.swift.bak"

sed -i.bak "s|<key>CFBundleShortVersionString</key><string>[^<]*</string>|<key>CFBundleShortVersionString</key><string>$FIREBASE_VERSION</string>|" \
  "$REPO_ROOT/scripts/build-firestore-internal.sh"
rm -f "$REPO_ROOT/scripts/build-firestore-internal.sh.bak"

echo ""
echo "==> Sources prepared for Firebase $FIREBASE_VERSION."
