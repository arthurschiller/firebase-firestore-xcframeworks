#!/usr/bin/env bash
# Rename `framework module BoringSSL-GRPC` → `framework module openssl_grpc`
# inside every slice of build/artifacts/openssl_grpc/openssl_grpc.xcframework.
#
# Why: Google's iOS Firebase release ships a CocoaPods-derived modulemap with
# a hyphenated module identifier (`BoringSSL-GRPC`) inside a framework dir
# named `openssl_grpc.framework`. Clang rejects hyphens in module identifiers,
# so any SPM source target listing `openssl_grpc` as a dependency fails to
# parse the modulemap and the build breaks. Aligning the module name with the
# framework name (the SPM convention) fixes this without touching the binary
# — module names are pure compile-time metadata, no symbols change.
#
# Idempotent — re-run after rebuilding or refreshing slices from Google.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCFW="${REPO_ROOT}/build/artifacts/openssl_grpc/openssl_grpc.xcframework"

if [[ ! -d "${XCFW}" ]]; then
  echo "openssl_grpc.xcframework not found at ${XCFW} — build it first via scripts/build-openssl_grpc.sh"
  exit 1
fi

count=0
while IFS= read -r mm; do
  if grep -q '^framework module BoringSSL-GRPC' "${mm}"; then
    sed -i.bak 's/^framework module BoringSSL-GRPC/framework module openssl_grpc/' "${mm}"
    rm "${mm}.bak"
    count=$((count + 1))
  fi
done < <(find "${XCFW}" -name "module.modulemap")

echo "Normalized ${count} modulemap(s)"
