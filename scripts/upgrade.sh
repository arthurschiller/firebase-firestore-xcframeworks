#!/usr/bin/env bash
# Upgrade the overlay to a new Firebase version end-to-end.
#
# Usage:
#   scripts/upgrade.sh <firebase_version>
# Example:
#   scripts/upgrade.sh 11.16.0
#
# What it does (each step is idempotent; safe to re-run if a build fails
# part-way through):
#   1. prepare-sources.sh  — clone firebase-ios-sdk + deps at right tags,
#                            download + extract Firebase.zip, sync vendored
#                            Firestore source, apply patches.
#   2. build-absl.sh       — rebuild absl.xcframework visionOS slices.
#   3. build-openssl_grpc.sh
#   4. build-grpc.sh
#   5. normalize-openssl-grpc-modulemap.sh — post-build modulemap rename.
#   6. build-leveldb.sh
#   7. build-firestore-internal.sh
#   8. build-release.sh    — zip, checksum, generate URL-mode Package.swift.
#
# After it finishes successfully, the script prints the exact git + gh
# commands to review, tag, push, and create the GitHub release. It does
# NOT auto-commit or auto-push — that's a deliberate manual gate so you
# can review the Package.swift diff before publishing.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <firebase_version>"
  echo "example: $0 11.16.0"
  exit 2
fi
FIREBASE_VERSION="$1"
REPO="${REPO:-arthurschiller/firebase-firestore-xcframeworks}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

step() {
  echo ""
  echo "###############################################################"
  echo "## $1"
  echo "###############################################################"
}

step "1/8  Prepare sources (clone, sync, patch)"
bash scripts/prepare-sources.sh "$FIREBASE_VERSION"

step "2/8  Build absl.xcframework"
bash scripts/build-absl.sh

step "3/8  Build openssl_grpc.xcframework"
bash scripts/build-openssl_grpc.sh

step "4/8  Build grpc + grpcpp xcframeworks"
bash scripts/build-grpc.sh

step "5/8  Normalize openssl_grpc modulemap (rename BoringSSL-GRPC → openssl_grpc)"
bash scripts/normalize-openssl-grpc-modulemap.sh

step "6/8  Build leveldb.xcframework"
bash scripts/build-leveldb.sh

step "7/8  Build FirebaseFirestoreInternal.xcframework"
bash scripts/build-firestore-internal.sh

step "8/8  Package release (zip + checksums + URL-mode Package.swift)"
bash scripts/build-release.sh "$FIREBASE_VERSION" "$REPO"

OUT="$REPO_ROOT/build/release/$FIREBASE_VERSION"

cat <<EOF

###############################################################
## DONE. Review before publishing.
###############################################################

Generated artifacts: $OUT

Suggested review + publish steps (run them by hand so you can sanity-check
the diff first):

  # 1. Adopt the generated URL-mode Package.swift
  cp $OUT/Package.swift Package.swift

  # 2. Review the diff (versions, checksums, version pins in build scripts)
  git diff Package.swift scripts/Package-source-compile.swift scripts/build-firestore-internal.sh Firestore FirebaseCore CoreOnly FirebaseFirestoreInternal

  # 3. Stage + commit
  git add -A
  git commit -m "Upgrade overlay to Firebase $FIREBASE_VERSION"

  # 4. Tag and push
  git tag $FIREBASE_VERSION
  git push origin main
  git push origin $FIREBASE_VERSION

  # 5. Create the GitHub release with all six xcframework zips
  gh release create $FIREBASE_VERSION \\
    $OUT/absl.xcframework.zip \\
    $OUT/openssl_grpc.xcframework.zip \\
    $OUT/grpc.xcframework.zip \\
    $OUT/grpcpp.xcframework.zip \\
    $OUT/leveldb.xcframework.zip \\
    $OUT/FirebaseFirestoreInternal.xcframework.zip \\
    -t "$FIREBASE_VERSION" \\
    -n "Firebase $FIREBASE_VERSION with visionOS slices for the six Firestore-related xcframeworks."

EOF
