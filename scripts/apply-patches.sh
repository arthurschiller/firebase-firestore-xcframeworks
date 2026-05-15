#!/usr/bin/env bash
# Re-apply our two patches to a freshly synced Firestore/Swift/Source/ tree.
# Idempotent — running it twice is a no-op. Called by prepare-sources.sh after
# rsync from upstream firebase-ios-sdk.
#
# Patch 1: SPM target rename. Upstream imports `FirebaseFirestoreInternalWrapper`,
#          our target is `_FirebaseFirestoreInternalWrapper` (underscored to avoid
#          collision with upstream firebase-ios-sdk in the same SPM graph).
#
# Patch 2: Module rename. Upstream uses `FirebaseFirestore.<Type>` as its own
#          module-qualified self-references; we renamed the module to
#          `FirebaseFirestorePrebuilt` to avoid the same collision.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/Firestore/Swift/Source"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: $SRC not found"
  exit 1
fi

echo "==> Patching imports: FirebaseFirestoreInternalWrapper → _FirebaseFirestoreInternalWrapper"
# perl with word-boundary lookbehind/lookahead so we don't touch any already-underscored occurrences.
find "$SRC" -name '*.swift' -print0 | xargs -0 perl -pi -e \
  's/(?<![_A-Za-z])FirebaseFirestoreInternalWrapper\b/_FirebaseFirestoreInternalWrapper/g'

echo "==> Patching self-module refs: FirebaseFirestore. → FirebaseFirestorePrebuilt."
find "$SRC" -name '*.swift' -print0 | xargs -0 perl -pi -e \
  's/(?<![_A-Za-z])FirebaseFirestore\./FirebaseFirestorePrebuilt./g'

echo "==> Verifying"
# Sanity-check: no remaining bare references that should have been patched.
# Uses perl rather than grep for the negative lookbehind.
if find "$SRC" -name '*.swift' -print0 | xargs -0 perl -lne 'print "$ARGV:$.: $_" if /(?<![_A-Za-z])FirebaseFirestoreInternalWrapper\b/' | grep .; then
  echo "ERROR: still found bare FirebaseFirestoreInternalWrapper after patching (see above)"
  exit 1
fi
if find "$SRC" -name '*.swift' -print0 | xargs -0 perl -lne 'print "$ARGV:$.: $_" if /(?<![_A-Za-z])FirebaseFirestore\./' | grep .; then
  echo "ERROR: still found bare FirebaseFirestore. after patching (see above)"
  exit 1
fi

echo "==> Done. Firestore/Swift/Source patched cleanly."
