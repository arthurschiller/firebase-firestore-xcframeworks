#!/usr/bin/env bash
# Build the consumer-shareable release: zip each xcframework, compute
# checksums, and generate a URL-mode Package.swift pointing at GH Release
# assets. Run before publishing a release.
#
# Usage:
#   scripts/build-release.sh <tag> [<repo>]
# Example:
#   scripts/build-release.sh 11.15.0 arthurschiller/firebase-firestore-xcframeworks
#
# Outputs:
#   build/release/<tag>/*.xcframework.zip — assets to upload as Release attachments
#   build/release/<tag>/Package.swift     — URL-mode manifest (ready to commit)

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <tag> [<owner/repo>]"
  exit 2
fi

TAG="$1"
REPO="${2:-arthurschiller/firebase-firestore-xcframeworks}"
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

declare -A CHECKSUMS

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
  CHECKSUMS["${fw_name}"]="$(swift package compute-checksum "${zip_path}")"
done

echo "==== Checksums ===="
for entry in "${FRAMEWORKS[@]}"; do
  IFS=":" read -r src_dir fw_name <<< "${entry}"
  echo "  ${fw_name}: ${CHECKSUMS[${fw_name}]}"
done

echo "==== Generating URL-mode Package.swift ===="
PKG_OUT="${OUT}/Package.swift"
PKG_BIN="${REPO_ROOT}/Package.swift"

# Start from current binary-mode Package.swift, swap each path: line for a
# url:+checksum: pair. Use a single python invocation for sanity.
python3 <<EOF > "${PKG_OUT}"
import re, sys

checksums = {
$(for entry in "${FRAMEWORKS[@]}"; do
    IFS=":" read -r src_dir fw_name <<< "${entry}"
    echo "    \"${fw_name}\": \"${CHECKSUMS[${fw_name}]}\","
done)
}
url_base = "${URL_BASE}"

with open("${PKG_BIN}") as f:
    pkg = f.read()

def replace(match):
    indent = match.group(1)
    name   = match.group(2)
    if name not in checksums:
        # Leave unknown binaryTargets as-is (e.g. test-only ones).
        return match.group(0)
    return (
        f'{indent}.binaryTarget(name: "{name}",\n'
        f'{indent}              url: "{url_base}/{name}.xcframework.zip",\n'
        f'{indent}              checksum: "{checksums[name]}")'
    )

# Match: <indent>.binaryTarget(name: "<name>",
#        <indent>              path: "build/artifacts/.../<name>.xcframework")
pattern = re.compile(
    r'([ \t]*)\.binaryTarget\(name:\s*"([^"]+)",\s*\n'
    r'\s*path:\s*"build/artifacts/[^"]+\.xcframework"\s*\)',
    re.MULTILINE
)
pkg = pattern.sub(replace, pkg)

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
