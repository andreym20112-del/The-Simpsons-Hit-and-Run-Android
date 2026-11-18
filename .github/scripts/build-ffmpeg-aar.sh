#!/usr/bin/env bash
# Compila FFmpeg 6.0.x para Android arm64-v8a y lo instala en el Maven local (~/.m2)
# como un AAR con Prefab, con las coordenadas que pide el proyecto:
#   com.fpliu.ndk.pkg.prefab.android.21:ffmpeg:6.0
# Variables opcionales: FFMPEG_TAG, NDK_VERSION, M2_REPO, WORK, SKIP_BUILD (solo para pruebas).
set -euo pipefail

FFMPEG_TAG="${FFMPEG_TAG:-n6.0.1}"
NDK_VERSION="${NDK_VERSION:-28.2.13676358}"
API=21
ABI=arm64-v8a
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
TOOLCHAIN="$SDK/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64"
WORK="${WORK:-$PWD/_ffmpeg_work}"
M2="${M2_REPO:-$HOME/.m2/repository}"
DEST="$M2/com/fpliu/ndk/pkg/prefab/android/21/ffmpeg/6.0"
MODULES="avcodec avformat avutil swresample swscale"
SRC="$WORK/ffmpeg-src"
PREFIX="$WORK/install"

mkdir -p "$WORK"

if [ -z "${SKIP_BUILD:-}" ]; then
  echo "== Descargando FFmpeg $FFMPEG_TAG"
  rm -rf "$SRC"
  git clone --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$SRC"

  echo "== Configurando"
  cd "$SRC"
  ./configure \
    --prefix="$PREFIX" \
    --enable-cross-compile --target-os=android --arch=aarch64 --cpu=armv8-a \
    --cc="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang" \
    --cxx="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang++" \
    --ar="$TOOLCHAIN/bin/llvm-ar" --nm="$TOOLCHAIN/bin/llvm-nm" \
    --ranlib="$TOOLCHAIN/bin/llvm-ranlib" --strip="$TOOLCHAIN/bin/llvm-strip" \
    --enable-shared --disable-static --enable-pic \
    --disable-programs --disable-doc --disable-debug --disable-symver \
    --disable-avdevice --disable-avfilter --disable-postproc \
    --disable-jni --disable-mediacodec --disable-vulkan \
    --extra-cflags="-O3 -fPIC" \
    --extra-ldflags="-Wl,-z,max-page-size=16384"

  echo "== Compilando"
  make -j"$(nproc)"
  make install-headers
  cd - >/dev/null

  echo "== Comprobando nombres de las librerias (soname sin version)"
  READELF="$TOOLCHAIN/bin/llvm-readelf"
  for m in $MODULES; do
    f="$SRC/lib$m/lib$m.so"
    [ -e "$f" ] || { echo "ERROR: no existe $f"; exit 1; }
    dyn="$("$READELF" -d "$f")"
    echo "$dyn" | grep -E "SONAME|NEEDED" | sed "s/^/  lib$m: /"
    echo "$dyn" | grep -q "SONAME.*\[lib$m\.so\]" || { echo "ERROR: soname de lib$m no es lib$m.so"; exit 1; }
    if echo "$dyn" | grep -E "NEEDED" | grep -qE "lib[a-z]+\.so\.[0-9]"; then
      echo "ERROR: lib$m depende de una libreria con nombre versionado"; exit 1
    fi
  done
fi

echo "== Empaquetando el AAR con Prefab"
AAR_DIR="$WORK/aar"
rm -rf "$AAR_DIR"
mkdir -p "$AAR_DIR"
for m in $MODULES; do
  mod="$AAR_DIR/prefab/modules/$m"
  mkdir -p "$mod/libs/android.$ABI"
  cp -L "$SRC/lib$m/lib$m.so" "$mod/libs/android.$ABI/lib$m.so"
  cp -r "$PREFIX/include" "$mod/include"
  printf '{\n  "library_name": "lib%s"\n}\n' "$m" > "$mod/module.json"
  printf '{\n  "abi": "%s",\n  "api": %s,\n  "ndk": 28,\n  "stl": "none",\n  "static": false\n}\n' "$ABI" "$API" \
    > "$mod/libs/android.$ABI/abi.json"
done
printf '{\n  "schema_version": 2,\n  "name": "ffmpeg",\n  "version": "6.0",\n  "dependencies": []\n}\n' \
  > "$AAR_DIR/prefab/prefab.json"
cat > "$AAR_DIR/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.fpliu.ndk.pkg.prefab.android.ffmpeg">
    <uses-sdk android:minSdkVersion="21" />
</manifest>
XML

mkdir -p "$DEST"
python3 - "$AAR_DIR" "$DEST/ffmpeg-6.0.aar" <<'PY'
import os, sys, zipfile, io
src, out = sys.argv[1], sys.argv[2]
# classes.jar vacio: algunos AAR lo exigen aunque no haya codigo Java
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as z:
    z.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("classes.jar", buf.getvalue())
    for root, _, files in os.walk(src):
        for f in sorted(files):
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, src).replace(os.sep, "/"))
PY
cat > "$DEST/ffmpeg-6.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.fpliu.ndk.pkg.prefab.android.21</groupId>
  <artifactId>ffmpeg</artifactId>
  <version>6.0</version>
  <packaging>aar</packaging>
  <name>ffmpeg</name>
</project>
POM
echo "== Listo: $DEST"
ls -la "$DEST"
