#!/usr/bin/env bash
# Build grpc.xcframework + grpcpp.xcframework with added visionOS slices.
#
# Strategy:
#   1. CMake-build gRPC for xros + xrsimulator with all deps as submodules
#      (gRPC_*_PROVIDER=module). Produces many .a files: libgrpc.a,
#      libgrpc++.a, libabsl_*.a, libupb_*.a, libre2.a, libz.a, libssl.a,
#      libcrypto.a, libcares.a, libprotobuf.a, libaddress_sorting.a.
#   2. Combine into grpc binary: libgrpc.a + abseil + upb + re2 + zlib +
#      address_sorting. Exclude ssl/crypto (kept as openssl_grpc.framework),
#      cares (disabled via -DGRPC_ARES=0), full protobuf (uses upb instead).
#   3. Combine into grpcpp binary: libgrpc++.a alone (small wrapper).
#   4. Wrap into frameworks reusing Google's Headers + Modules verbatim.
#   5. Merge with Google's existing xcframeworks.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_build_common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRPC_SRC="$REPO_ROOT/build/sources/grpc"
GOOGLE_GRPC="$REPO_ROOT/build/downloads/Firebase-extracted/Firebase/FirebaseFirestore/grpc.xcframework"
GOOGLE_GRPCPP="$REPO_ROOT/build/downloads/Firebase-extracted/Firebase/FirebaseFirestore/grpcpp.xcframework"
OUT="$REPO_ROOT/build/artifacts"
SLICES_GRPC="$OUT/grpc-slices"
SLICES_GRPCPP="$OUT/grpcpp-slices"

for p in "$GRPC_SRC" "$GOOGLE_GRPC" "$GOOGLE_GRPCPP"; do
  if [ ! -e "$p" ]; then echo "ERROR: missing $p"; exit 1; fi
done

# Patch zlib's CMakeLists: drop gz*.c sources. With -DZ_SOLO=1 (set below)
# zlib's gzguts.h doesn't define gzFile, so those files fail to compile.
# gRPC only uses zlib for inflate/deflate, never gz*, so safe to remove.
ZLIB_CMAKE="$GRPC_SRC/third_party/zlib/CMakeLists.txt"
if grep -q "^    gzclose\.c$" "$ZLIB_CMAKE"; then
  echo "Patching zlib CMakeLists (removing gz*.c sources)..."
  sed -i.bak '/^    gzclose\.c$/d; /^    gzlib\.c$/d; /^    gzread\.c$/d; /^    gzwrite\.c$/d' "$ZLIB_CMAKE"
fi

rm -rf "$OUT/grpc" "$OUT/grpcpp" "$SLICES_GRPC" "$SLICES_GRPCPP"
mkdir -p "$OUT/grpc" "$OUT/grpcpp" "$SLICES_GRPC" "$SLICES_GRPCPP"

REF_GRPC="$GOOGLE_GRPC/ios-arm64/grpc.framework"
REF_GRPCPP="$GOOGLE_GRPCPP/ios-arm64/grpcpp.framework"

build_slice() {
  local sdk="$1"
  local slice_name="$2"
  local platform_name="$3"
  local min_os="$4"

  local build_dir="$OUT/grpc-build-$sdk"
  local fw_grpc="$SLICES_GRPC/$slice_name/grpc.framework"
  local fw_grpcpp="$SLICES_GRPCPP/$slice_name/grpcpp.framework"

  echo ""
  echo "=========================================="
  echo "Building gRPC for $sdk (arm64)"
  echo "=========================================="

  if [ ! -f "$build_dir/CMakeCache.txt" ]; then
    mkdir -p "$build_dir"
    cmake -S "$GRPC_SRC" -B "$build_dir" \
      -G "Unix Makefiles" \
      "${CMAKE_CCACHE_ARGS[@]}" \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_SYSTEM_NAME=visionOS \
      -DCMAKE_OSX_SYSROOT="$sdk" \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_os" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DBUILD_SHARED_LIBS=OFF \
      -DgRPC_BUILD_TESTS=OFF \
      -DgRPC_BUILD_CODEGEN=OFF \
      -DgRPC_BUILD_GRPC_CSHARP_PLUGIN=OFF \
      -Dprotobuf_INSTALL=OFF \
      -Dutf8_range_ENABLE_INSTALL=OFF \
      -DABSL_ENABLE_INSTALL=OFF \
      -DgRPC_BUILD_GRPC_NODE_PLUGIN=OFF \
      -DgRPC_BUILD_GRPC_OBJECTIVE_C_PLUGIN=OFF \
      -DgRPC_BUILD_GRPC_PHP_PLUGIN=OFF \
      -DgRPC_BUILD_GRPC_PYTHON_PLUGIN=OFF \
      -DgRPC_BUILD_GRPC_RUBY_PLUGIN=OFF \
      -DgRPC_INSTALL=OFF \
      -DgRPC_ABSL_PROVIDER=module \
      -DgRPC_SSL_PROVIDER=module \
      -DgRPC_PROTOBUF_PROVIDER=module \
      -DgRPC_ZLIB_PROVIDER=module \
      -DgRPC_CARES_PROVIDER=module \
      -DgRPC_RE2_PROVIDER=module \
      -DOPENSSL_NO_ASM=1 \
      -DCMAKE_C_FLAGS="-DOPENSSL_NO_ASM -DBORINGSSL_PREFIX=GRPC -DGRPC_ARES=0 -DZ_SOLO=1 -fvisibility=hidden -fno-common" \
      -DCMAKE_CXX_FLAGS="-DOPENSSL_NO_ASM -DBORINGSSL_PREFIX=GRPC -DGRPC_ARES=0 -DZ_SOLO=1 -fvisibility=hidden -fno-common -fno-exceptions -fno-rtti"
  fi

  cmake --build "$build_dir" --target grpc grpc++ -j$PARALLEL_JOBS

  # Collect archives to bundle into grpc binary.
  # Include: gRPC core + upb + re2 + zlib + address_sorting.
  # Exclude: BoringSSL (separate framework), c-ares (disabled),
  #          full protobuf (using upb),
  #          abseil (separate framework — bundling causes dup-symbol link errors).
  # Helper function instead of `{ … } | sort -u` group inline in <(...),
  # because bash 3.2 (the macOS system bash used by GitHub Actions runners)
  # mis-parses the inline group with embedded comments.
  collect_grpc_libs() {
    find "$build_dir" -name "libgrpc.a" -type f
    # libgpr.a: grpc's portable runtime (gpr_malloc / gpr_mu_init).
    find "$build_dir" -name "libgpr.a" -type f
    # upb / utf8_range_lib emit at $build_dir root in this CMake config
    # (no third_party/upb/ subdir) — earlier patterns missed them.
    find "$build_dir" -maxdepth 1 -name "libupb_*.a" -type f 2>/dev/null
    find "$build_dir" -maxdepth 1 -name "libutf8_range_lib.a" -type f 2>/dev/null
    find "$build_dir/third_party/re2" -name "libre2.a" -type f 2>/dev/null
    find "$build_dir/third_party/zlib" \( -name "libz.a" -o -name "libzlibstatic.a" \) -type f 2>/dev/null
    find "$build_dir" -name "libaddress_sorting.a" -type f 2>/dev/null
  }

  grpc_libs=()
  while IFS= read -r f; do grpc_libs+=("$f"); done < <(collect_grpc_libs | sort -u)

  if [ "${#grpc_libs[@]}" -lt 5 ]; then
    echo "ERROR: too few grpc dependency archives found (${#grpc_libs[@]})"
    find "$build_dir" -name "*.a" -type f | head -30
    exit 1
  fi
  echo "Bundling ${#grpc_libs[@]} archives into grpc binary"

  mkdir -p "$fw_grpc/Headers" "$fw_grpc/Modules"
  libtool -static -o "$fw_grpc/grpc" "${grpc_libs[@]}" 2>&1 | grep -v "has no symbols" | head -20 || true

  # grpc++ is just the C++ wrapper
  local grpcpp_lib
  grpcpp_lib="$(find "$build_dir" -name "libgrpc++.a" -type f | head -1)"
  if [ -z "$grpcpp_lib" ]; then
    echo "ERROR: libgrpc++.a not found"
    exit 1
  fi
  mkdir -p "$fw_grpcpp/Headers" "$fw_grpcpp/Modules"
  cp "$grpcpp_lib" "$fw_grpcpp/grpcpp"

  # Copy headers + module map from Google's iOS slice (same source → identical)
  cp -R "$REF_GRPC/Headers/." "$fw_grpc/Headers/"
  cp -R "$REF_GRPC/Modules/." "$fw_grpc/Modules/"
  cp -R "$REF_GRPCPP/Headers/." "$fw_grpcpp/Headers/"
  cp -R "$REF_GRPCPP/Modules/." "$fw_grpcpp/Modules/"

  for fw in "$fw_grpc" "$fw_grpcpp"; do
    name=$(basename "$fw" .framework)
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>org.cocoapods.$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.69.1</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform_name</string></array>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$min_os</string>
</dict>
</plist>
PLIST
  done

  echo "Built $fw_grpc ($(du -h $fw_grpc/grpc | cut -f1))"
  echo "Built $fw_grpcpp ($(du -h $fw_grpcpp/grpcpp | cut -f1))"
}

build_slice xros          xros-arm64           XROS         1.0
build_slice xrsimulator   xros-arm64-simulator XRSimulator  1.0

echo ""
echo "=========================================="
echo "Merging xcframeworks"
echo "=========================================="

for pair in "grpc:$GOOGLE_GRPC:$SLICES_GRPC" "grpcpp:$GOOGLE_GRPCPP:$SLICES_GRPCPP"; do
  IFS=':' read -r name google_xcf slices <<< "$pair"
  merged="$OUT/$name/$name.xcframework"
  rm -rf "$merged"
  xcodebuild -create-xcframework \
    -framework "$google_xcf/ios-arm64/$name.framework" \
    -framework "$google_xcf/ios-arm64_x86_64-simulator/$name.framework" \
    -framework "$google_xcf/ios-arm64_x86_64-maccatalyst/$name.framework" \
    -framework "$google_xcf/macos-arm64_x86_64/$name.framework" \
    -framework "$google_xcf/tvos-arm64/$name.framework" \
    -framework "$google_xcf/tvos-arm64_x86_64-simulator/$name.framework" \
    -framework "$slices/xros-arm64/$name.framework" \
    -framework "$slices/xros-arm64-simulator/$name.framework" \
    -output "$merged"
  echo "=== $name xcframework ==="
  ls "$merged"
done
