#!/usr/bin/env bash
# Verify the release zips built by build-release.sh before anything is
# committed, tagged or uploaded.
#
# Checks, on the unzipped release assets (exactly what consumers download):
#   1. Every FirebaseFirestoreInternal slice embeds the exact TLS root
#      certificate bundle from the vendored
#      Firestore/core/src/remote/grpc_root_certificates_generated.cc.
#      Our xros slices are built from source, so this proves the vendored
#      bundle reached the binary; Google's slices must carry the same one.
#   2. Every non-xros slice of every asset is byte-identical to Google's
#      Firebase.zip. Consumers such as ARCore link against those slices and
#      expect Google's exact bytes.
#
# Usage:
#   scripts/verify-release.sh <tag>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <tag>"
  exit 2
fi
TAG="$1"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$REPO_ROOT/build/release/$TAG"
GOOGLE_DIR="$REPO_ROOT/build/downloads/Firebase-extracted/Firebase/FirebaseFirestore"
CERTS_CC="$REPO_ROOT/Firestore/core/src/remote/grpc_root_certificates_generated.cc"
FRAMEWORKS=(absl openssl_grpc grpc grpcpp leveldb FirebaseFirestoreInternal)

UNZIP_DIR="$(mktemp -d)"
trap 'rm -rf "$UNZIP_DIR"' EXIT

for name in "${FRAMEWORKS[@]}"; do
  unzip -q "$RELEASE_DIR/$name.xcframework.zip" -d "$UNZIP_DIR"
done

failures=0

echo "==> Root certificate bundle in FirebaseFirestoreInternal"
binaries=()
while IFS= read -r binary; do
  binaries+=("$binary")
done < <(find "$UNZIP_DIR/FirebaseFirestoreInternal.xcframework" \
           -path "*/FirebaseFirestoreInternal.framework/*" \
           -name FirebaseFirestoreInternal -type f | sort)
if ! python3 -I - "$CERTS_CC" "${binaries[@]}" <<'EOF'
import re, sys

source = open(sys.argv[1]).read()
array = source.split("grpc_root_certificates_generated_data[] = {", 1)[1].split("};", 1)[0]
bundle = bytes(int(h, 16) for h in re.findall(r"0x([0-9a-fA-F]{2})", array)).rstrip(b"\0")
print(f"    reference: {len(bundle)} bytes, {bundle.count(b'BEGIN CERTIFICATE')} certificates")

ok = True
for path in sys.argv[2:]:
    found = bundle in open(path, "rb").read()
    ok &= found
    print(f"    {'OK  ' if found else 'FAIL'} {path.split('.xcframework/', 1)[1]}")
sys.exit(0 if ok else 1)
EOF
then
  failures=$((failures + 1))
fi

echo "==> Non-visionOS slices match Google's Firebase.zip"
for name in "${FRAMEWORKS[@]}"; do
  for google_slice in "$GOOGLE_DIR/$name.xcframework"/*-*/; do
    slice="$(basename "$google_slice")"
    if diff -rq --no-dereference "$google_slice" "$UNZIP_DIR/$name.xcframework/$slice" >/dev/null 2>&1; then
      echo "    OK   $name/$slice"
    else
      echo "    FAIL $name/$slice"
      failures=$((failures + 1))
    fi
  done
done

if [[ $failures -gt 0 ]]; then
  echo "ERROR: release verification failed ($failures failing checks)"
  exit 1
fi
echo "==> Release $TAG verified."
