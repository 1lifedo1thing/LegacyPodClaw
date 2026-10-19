#!/bin/sh
set -eu

WOLFSSL_TAG="v5.9.4-stable"
SDK="${THEOS:?set THEOS}/sdks/iPhoneOS14.5.sdk"
VENDOR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone -q --depth 1 --branch "$WOLFSSL_TAG" https://github.com/wolfSSL/wolfssl.git "$WORK/src"
cd "$WORK/src"

CFLAGS="-arch armv7 -isysroot $SDK -miphoneos-version-min=6.0 -Os -fvisibility=default \
  -DWOLFSSL_USER_SETTINGS -I$VENDOR/wolfssl-build -I. -w"

mkdir -p "$WORK/obj"
for f in src/internal.c src/keys.c src/ssl.c src/tls.c src/tls13.c src/wolfio.c \
         $(ls wolfcrypt/src/*.c | grep -vE '/(misc|evp)\.c$'); do
  xcrun clang $CFLAGS -c "$f" -o "$WORK/obj/$(echo "$f" | tr / _).o"
done

rm -f "$VENDOR/libwolfssl.a"
xcrun libtool -static -o "$VENDOR/libwolfssl.a" "$WORK"/obj/*.o

rm -rf "$VENDOR/wolfssl/include"
mkdir -p "$VENDOR/wolfssl/include"
find wolfssl -name '*.h' | while read -r h; do
  mkdir -p "$VENDOR/wolfssl/include/$(dirname "$h")"
  cp "$h" "$VENDOR/wolfssl/include/$h"
done

echo "$WOLFSSL_TAG" > "$VENDOR/wolfssl/VERSION"
lipo -info "$VENDOR/libwolfssl.a"
