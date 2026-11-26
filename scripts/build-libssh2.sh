#!/bin/bash
# Builds OpenSSL + libssh2 (no zlib) for iOS device and simulator and packages
# Packages/SSHKit/Vendor/CLibSSH2.xcframework. Output is gitignored.
set -euo pipefail

OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
# libssh2 master at a pinned commit (CVE fixes, ML-KEM); the source archive has no configure, so CMake builds it.
LIBSSH2_COMMIT="dd1546700d0ed8ff7138bc1ccc288286fb3ab2b4"
LIBSSH2_SHA256="67d20d434055faef76439c6829ab253c892fcdd68d9a9c86cf5824bd8366e6eb"
LIBSSH2_URL="https://github.com/libssh2/libssh2/archive/${LIBSSH2_COMMIT}.tar.gz"
if [ -z "${CMAKE:-}" ]; then
  if command -v cmake >/dev/null 2>&1; then
    CMAKE="$(command -v cmake)"
  elif [ -x /opt/homebrew/bin/cmake ]; then
    CMAKE="/opt/homebrew/bin/cmake"
  elif [ -x /usr/local/bin/cmake ]; then
    CMAKE="/usr/local/bin/cmake"
  else
    CMAKE=""
  fi
fi
if [ -z "$CMAKE" ] || [ ! -x "$CMAKE" ]; then
  echo "error: cmake not found or not executable (checked PATH, /opt/homebrew/bin/cmake, /usr/local/bin/cmake)" >&2
  exit 1
fi
MIN_IOS="18.0"
# Keep host settings out of the cross build: no macOS deployment target, no pkg-config probing of Homebrew.
unset MACOSX_DEPLOYMENT_TARGET
export PKG_CONFIG_LIBDIR=""

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Packages/SSHKit/Vendor"
# Keyed by version and deployment target so a bump never reuses stale archives.
WORK="${BUILD_LIBSSH2_WORK:-$ROOT/.build-libssh2/openssl-$OPENSSL_VERSION-libssh2-${LIBSSH2_COMMIT:0:7}-ios$MIN_IOS}"
NCPU="$(sysctl -n hw.ncpu)"

mkdir -p "$WORK/src" "$OUT"

fetch() { # url sha256 file
  local f="$WORK/src/$3"
  if [ ! -f "$f" ]; then curl -fsSL -o "$f" "$1"; fi
  echo "$2  $f" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $3" >&2; rm -f "$f"; exit 1; }
}
fetch "$OPENSSL_URL" "$OPENSSL_SHA256" "openssl.tar.gz"
fetch "$LIBSSH2_URL" "$LIBSSH2_SHA256" "libssh2.tar.gz"

# build_one <name> <sdk> <arch> <target-triple-suffix>
build_one() {
  local name="$1" sdk="$2" arch="$3" triple="$4"
  local dir="$WORK/$name" prefix="$WORK/$name/install"
  [ -f "$dir/libssh2-all.a" ] && return 0
  rm -rf "$dir"; mkdir -p "$dir/src-ossl" "$dir/src-ssh2" "$prefix"
  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local cc; cc="$(xcrun --sdk "$sdk" --find clang)"
  local cflags="-arch $arch -isysroot $sysroot --target=$triple -O2"

  tar -xzf "$WORK/src/openssl.tar.gz" -C "$dir/src-ossl" --strip-components=1
  ( cd "$dir/src-ossl"
    CC="$cc $cflags" ./Configure "$( [ "$arch" = x86_64 ] && echo darwin64-x86_64-cc || echo darwin64-arm64-cc )" \
      no-shared no-dso no-tests no-asm no-zlib no-comp no-async no-ui-console no-engine \
      --prefix="$prefix" --openssldir="$prefix/ssl" >/dev/null
    make -j"$NCPU" build_libs >/dev/null
    make install_dev >/dev/null )

  tar -xzf "$WORK/src/libssh2.tar.gz" -C "$dir/src-ssh2" --strip-components=1
  ( cd "$dir/src-ssh2"
    "$CMAKE" -S . -B build -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_C_COMPILER="$cc" -DCMAKE_C_FLAGS="$cflags" \
      -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES="$arch" \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DCRYPTO_BACKEND=OpenSSL \
      -DOPENSSL_ROOT_DIR="$prefix" -DOPENSSL_USE_STATIC_LIBS=ON \
      -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
      -DENABLE_ZLIB_COMPRESSION=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
      -DLIBSSH2_NO_DEPRECATED=OFF >/dev/null
    "$CMAKE" --build build -j"$NCPU" >/dev/null
    "$CMAKE" --install build >/dev/null )

  local lt_log="$dir/libtool.log"
  if ! libtool -static -o "$dir/libssh2-all.a" "$prefix/lib/libssh2.a" "$prefix/lib/libssl.a" "$prefix/lib/libcrypto.a" 2>"$lt_log"; then
    cat "$lt_log" >&2
    return 1
  fi
}

build_one ios-arm64        iphoneos        arm64  "arm64-apple-ios${MIN_IOS}"
build_one sim-arm64        iphonesimulator arm64  "arm64-apple-ios${MIN_IOS}-simulator"
build_one sim-x86_64       iphonesimulator x86_64 "x86_64-apple-ios${MIN_IOS}-simulator"

# Headers + module map
HDR="$WORK/headers"
rm -rf "$HDR"; mkdir -p "$HDR"
cp "$WORK/ios-arm64/install/include/"libssh2*.h "$HDR/"
cat > "$HDR/module.modulemap" <<'MM'
module CLibSSH2 {
    header "libssh2.h"
    header "libssh2_sftp.h"
    export *
}
MM

mkdir -p "$WORK/sim-fat"
lipo -create "$WORK/sim-arm64/libssh2-all.a" "$WORK/sim-x86_64/libssh2-all.a" -output "$WORK/sim-fat/libssh2-all.a"

rm -rf "$OUT/CLibSSH2.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/ios-arm64/libssh2-all.a" -headers "$HDR" \
  -library "$WORK/sim-fat/libssh2-all.a" -headers "$HDR" \
  -output "$OUT/CLibSSH2.xcframework"
echo "OK: $OUT/CLibSSH2.xcframework"
