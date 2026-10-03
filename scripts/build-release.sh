#!/usr/bin/env bash
# Build the consumer-shareable release: zip each xcframework, compute
# checksums, and generate a URL-mode Package.swift pointing at GH Release
# assets. Run before publishing a release.
#
# Usage:
#   scripts/build-release.sh <tag> [<repo>] [<firebase_version>]
# Example:
#   scripts/build-release.sh 11.15.0 arthurschiller/firebase-firestore-xcframeworks 11.15.0
#
# Outputs:
#   build/release/<tag>/*.xcframework.zip — assets to upload as Release attachments
#   build/release/<tag>/Package.swift     — URL-mode manifest (ready to commit)

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <tag> [<owner/repo>] [<firebase_version>]"
  exit 2
fi

TAG="$1"
REPO="${2:-arthurschiller/firebase-firestore-xcframeworks}"
# Optional 3rd arg: the underlying Firebase iOS SDK version. When set, the
# generated manifest's `firebaseVersion` constant and the firebase-ios-sdk
# `exact:` pin are bumped to it. Defaults to empty (leave both as-is) because
# the overlay tag can differ from the Firebase version (tag scheme <fbver>.<patch>).
FIREBASE_VERSION="${3:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

OUT="${REPO_ROOT}/build/release/${TAG}"
rm -rf "${OUT}"
mkdir -p "${OUT}"

ARTIFACT_DIR="${REPO_ROOT}/build/artifacts"
URL_BASE="https://github.com/${REPO}/releases/download/${TAG}"

# Map xcframework directory in build/artifacts/ → final zip asset name.
# Tuple format: "<source_dir>:<framework_name>". Asset name is <framework_name>.xcframework.zip.
declare -a FRAMEWORKS=(
  "absl:absl"
  "openssl_grpc:openssl_grpc"
  "grpc:grpc"
  "grpcpp:grpcpp"
  "leveldb:leveldb"
  "FirebaseFirestoreInternal:FirebaseFirestoreInternal"
)

# Parallel arrays instead of `declare -A` so the script runs under macOS's
# stock bash 3.2 (used by GitHub Actions runners).
CHECKSUM_NAMES=()
CHECKSUM_VALUES=()

lookup_checksum() {
  local name="$1" i
  for i in "${!CHECKSUM_NAMES[@]}"; do
    if [[ "${CHECKSUM_NAMES[$i]}" == "$name" ]]; then
      echo "${CHECKSUM_VALUES[$i]}"
      return 0
    fi
  done
  return 1
}

echo "==== Zipping xcframeworks ===="
for entry in "${FRAMEWORKS[@]}"; do
  IFS=":" read -r src_dir fw_name <<< "${entry}"
  xcfw_path="${ARTIFACT_DIR}/${src_dir}/${fw_name}.xcframework"
  if [[ ! -d "${xcfw_path}" ]]; then
    echo "ERROR: missing ${xcfw_path}"
    exit 1
  fi
  zip_path="${OUT}/${fw_name}.xcframework.zip"
  (
    cd "${ARTIFACT_DIR}/${src_dir}" && zip -ryqo "${zip_path}" "${fw_name}.xcframework"
  )
  echo "  $(du -h "${zip_path}" | awk '{print $1}')\t${fw_name}.xcframework.zip"

  # swift package compute-checksum gives the value SPM expects for binaryTarget.
  CHECKSUM_NAMES+=("${fw_name}")
  CHECKSUM_VALUES+=("$(swift package compute-checksum "${zip_path}")")
done

echo "==== Checksums ===="
for i in "${!CHECKSUM_NAMES[@]}"; do
  echo "  ${CHECKSUM_NAMES[$i]}: ${CHECKSUM_VALUES[$i]}"
done

echo "==== Generating URL-mode Package.swift ===="
PKG_OUT="${OUT}/Package.swift"
PKG_BIN="${REPO_ROOT}/Package.swift"

# Rewrite the root (binary-mode) Package.swift into a URL-mode release manifest.
# For each of the six binaryTargets, set url: + checksum: for this TAG/REPO.
#
# Idempotent and robust to the manifest's current shape:
#   - works whether a target is in path-mode (path: "build/artifacts/...") or
#     already url-mode (re-running produces the same output);
#   - keyed on the SPM *target* name, which differs from the asset name
#     (asset "absl" -> target "firestore_absl", asset
#     "FirebaseFirestoreInternal" -> target "_FirebaseFirestoreInternal").
#
# If a firebase version was supplied, also bump the `firebaseVersion` constant
# and the firebase-ios-sdk `exact:` pin.
python3 <<EOF > "${PKG_OUT}"
import re, sys

# (asset_name, checksum) — asset_name is the zip / checksum key.
checksums = [
$(for i in "${!CHECKSUM_NAMES[@]}"; do
    echo "    (\"${CHECKSUM_NAMES[$i]}\", \"${CHECKSUM_VALUES[$i]}\"),"
done)
]
# asset name -> SPM binaryTarget name used in the consumer manifest.
target_name = {
    "absl": "firestore_absl",
    "openssl_grpc": "firestore_openssl_grpc",
    "grpc": "firestore_grpc",
    "grpcpp": "firestore_grpcpp",
    "leveldb": "firestore_leveldb",
    "FirebaseFirestoreInternal": "_FirebaseFirestoreInternal",
}
url_base = "${URL_BASE}"
firebase_version = "${FIREBASE_VERSION}"

with open("${PKG_BIN}") as f:
    pkg = f.read()

def one_target(m):
    # Guard against a non-greedy match overshooting into an adjacent target.
    return m is not None and m.group().count(".binaryTarget(") == 1

for asset, chk in checksums:
    tgt = target_name.get(asset, asset)
    url = f"{url_base}/{asset}.xcframework.zip"
    name_pat = r'\.binaryTarget\(name:\s*"' + re.escape(tgt) + r'",'
    url_re  = re.compile(name_pat + r'.*?checksum:\s*"[^"]*"\s*\)', re.DOTALL)
    path_re = re.compile(name_pat + r'.*?path:\s*"[^"]*"\s*\)', re.DOTALL)

    m = url_re.search(pkg)
    if not one_target(m):
        m = path_re.search(pkg)
    if not one_target(m):
        sys.stderr.write(f"WARN: binaryTarget '{tgt}' not found (skipped)\n")
        continue

    # Preserve the target's existing indentation; rebuild a clean url block
    # (any stale per-target comment is dropped — the file header documents the
    # ABI/packaging hacks generically).
    line_start = pkg.rfind("\n", 0, m.start()) + 1
    indent = pkg[line_start:m.start()]
    pad = indent + " " * len(".binaryTarget(")
    new = (f'.binaryTarget(name: "{tgt}",\n'
           f'{pad}url: "{url}",\n'
           f'{pad}checksum: "{chk}")')
    pkg = pkg[:m.start()] + new + pkg[m.end():]

if firebase_version:
    pkg = re.sub(r'let firebaseVersion = "[^"]*"',
                 f'let firebaseVersion = "{firebase_version}"', pkg, count=1)
    pkg = re.sub(r'(firebase-ios-sdk\.git",\s*exact:\s*)"[^"]*"',
                 r'\g<1>"' + firebase_version + '"', pkg, count=1)

sys.stdout.write(pkg)
EOF

echo "==== Verifying generated Package.swift parses ===="
# Trial-replace and dump-package to make sure SPM accepts the URL-mode manifest.
# Roll back at the end no matter what.
cp "${PKG_BIN}" "${PKG_BIN}.precheck-backup"
cp "${PKG_OUT}" "${PKG_BIN}"
if swift package dump-package > /dev/null 2>&1; then
  echo "  Package.swift parses cleanly"
else
  echo "  Package.swift FAILED to parse:"
  swift package dump-package 2>&1 | tail -20
  mv "${PKG_BIN}.precheck-backup" "${PKG_BIN}"
  exit 1
fi
mv "${PKG_BIN}.precheck-backup" "${PKG_BIN}"

echo "==== Done ===="
ls -lh "${OUT}/"
cat <<EOF

Next steps (do these by hand or via 'gh release create'):
  1. gh repo create ${REPO} --public --source=. --remote=origin --push     # if repo doesn't exist
  2. cp ${OUT}/Package.swift Package.swift
  3. git add Package.swift && git commit -m "Switch to URL-mode binaryTargets for ${TAG} release"
  4. git tag ${TAG} && git push origin ${TAG}
  5. gh release create ${TAG} \\
     ${OUT}/absl.xcframework.zip \\
     ${OUT}/openssl_grpc.xcframework.zip \\
     ${OUT}/grpc.xcframework.zip \\
     ${OUT}/grpcpp.xcframework.zip \\
     ${OUT}/leveldb.xcframework.zip \\
     ${OUT}/FirebaseFirestoreInternal.xcframework.zip \\
     --title "${TAG}" \\
     --notes "Firebase ${TAG} with visionOS slices for the 6 Firestore-related xcframeworks."
EOF
