#!/bin/bash
# Builds OpenSSL + libssh2 (no zlib) for iOS device and simulator and packages
# Packages/SSHKit/Vendor/CLibSSH2.xcframework. Output is gitignored.
set -euo pipefail

OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
LIBSSH2_VERSION="1.11.1"
LIBSSH2_SHA256="d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"
LIBSSH2_URL="https://github.com/libssh2/libssh2/releases/download/libssh2-${LIBSSH2_VERSION}/libssh2-${LIBSSH2_VERSION}.tar.gz"
MIN_IOS="18.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Packages/SSHKit/Vendor"
# Keyed by version so a version bump never reuses stale archives.
WORK="${BUILD_LIBSSH2_WORK:-$ROOT/.build-libssh2/openssl-$OPENSSL_VERSION-libssh2-$LIBSSH2_VERSION}"
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
    ./configure --host="$arch-apple-darwin" --prefix="$prefix" \
      CC="$cc" CFLAGS="$cflags" LDFLAGS="-arch $arch -isysroot $sysroot" \
      --disable-shared --enable-static --with-crypto=openssl \
      --with-libssl-prefix="$prefix" --without-libz \
      --disable-examples-build --disable-docker-tests --disable-sshd-tests --disable-tests --disable-debug >/dev/null
    make -j"$NCPU" >/dev/null
    make install >/dev/null )

  libtool -static -o "$dir/libssh2-all.a" "$prefix/lib/libssh2.a" "$prefix/lib/libssl.a" "$prefix/lib/libcrypto.a" 2>/dev/null
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
