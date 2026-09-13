#!/usr/bin/env bash
#
# Build the minimal UMS-helper APK for the Tolino Shine 3.
# Requires: Android SDK (aapt2/d8/apksigner/zipalign) + a JDK.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="${SDK:-/home/leon/Android/Sdk}"
BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
ANDROID_JAR="$(ls -d "$SDK"/platforms/* 2>/dev/null | sort -V | head -1)/android.jar"
JAVA_BIN="${JAVA_BIN:-/usr/lib/jvm/java-21-openjdk/bin}"
OUT="$HERE/build"

: "${BT:?Android build-tools not found}"
: "${ANDROID_JAR:?android.jar not found}"
[ -x "$JAVA_BIN/javac" ] || { echo "FATAL: no javac at $JAVA_BIN"; exit 1; }

export PATH="$JAVA_BIN:$PATH"
export JAVA_HOME="$(dirname "$JAVA_BIN")"
rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/dex"

echo "== using =="
echo "   aapt2       : $BT/aapt2"
echo "   android.jar : $ANDROID_JAR"
echo "   javac       : $("$JAVA_BIN/javac" -version 2>&1)"

echo "== 1. link resources + manifest =="
"$BT/aapt2" link \
  -o "$OUT/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$HERE/AndroidManifest.xml" \
  --min-sdk-version 19 --target-sdk-version 19
echo "   -> $(stat -c%s "$OUT/base.apk") bytes"

echo "== 2. compile java =="
"$JAVA_BIN/javac" -source 8 -target 8 -nowarn \
  -bootclasspath "$ANDROID_JAR" \
  -d "$OUT/classes" \
  $(find "$HERE/src" -name '*.java') 2>&1 | grep -v 'bootstrap class path' || true
find "$OUT/classes" -name '*.class' | sed 's/^/   /'

echo "== 3. dex =="
"$BT/d8" --min-api 19 --lib "$ANDROID_JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
ls -la "$OUT/dex" | sed 's/^/   /'

echo "== 4. add classes.dex to the apk =="
( cd "$OUT/dex" && zip -q -u "$OUT/base.apk" classes.dex )
unzip -l "$OUT/base.apk" | grep -E 'classes.dex|AndroidManifest' | sed 's/^/   /'

echo "== 5. keystore =="
if [ ! -f "$HERE/debug.keystore" ]; then
  "$JAVA_BIN/keytool" -genkeypair -keystore "$HERE/debug.keystore" \
    -storepass android -keypass android -alias androiddebugkey \
    -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000 \
    >/dev/null 2>&1
  echo "   generated debug.keystore"
else
  echo "   reusing debug.keystore"
fi

echo "== 6. zipalign + sign (v1 required for API 19) =="
"$BT/zipalign" -f 4 "$OUT/base.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign \
  --ks "$HERE/debug.keystore" --ks-pass pass:android --key-pass pass:android \
  --v1-signing-enabled true --v2-signing-enabled false \
  --out "$HERE/umshelper.apk" "$OUT/aligned.apk"

echo "== 7. verify =="
"$BT/apksigner" verify --verbose "$HERE/umshelper.apk" | head -6
echo
echo "RESULT: $HERE/umshelper.apk  ($(stat -c%s "$HERE/umshelper.apk") bytes)"
"$BT/aapt2" dump badging "$HERE/umshelper.apk" 2>/dev/null | head -8
