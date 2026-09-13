#!/usr/bin/env bash
# Step 25 - turn the official KOReader APK into one that can be a launcher.
#
# WHY THIS STEP EXISTS
#   The official KOReader release does NOT declare android.intent.category.HOME
#   (verified on v2026.07.1: 0 occurrences, signed by "CN=Qingping Hou"), so
#   Android will never offer it as a home app. Meanwhile 30-debloat.sh deletes
#   EPubProd.apk, which is the stock launcher and the only other HOME app on the
#   device. Install the official APK, debloat, and the device boots to a screen
#   with nothing on it.
#
#   So KOReader has to be patched: add HOME + DEFAULT to MainActivity's MAIN
#   intent-filter, rebuild, re-sign. See docs/koreader-as-home.md.
#
# COST, stated up front: the result is debug-signed, so it can never again be
#   updated with `adb install -r` from the official APK. Every future update is
#   uninstall -> prepare -> install, and the uninstall takes KOReader's app data
#   with it (books and reading positions live on the user partition and survive).
#
# Usage:
#   scripts/25-prepare-koreader.sh                     # download + patch + sign
#   scripts/25-prepare-koreader.sh <official.apk>      # use a local copy
#   scripts/25-prepare-koreader.sh --install [apk]     # ... and adb install it
#
# Environment:
#   KOREADER_VERSION    release to fetch            (default 2026.07.1)
#   KOREADER_ABI        target ABI suffix           (default android-arm)
#   APKTOOL             path to apktool.jar
#   UBER_APK_SIGNER     path to uber-apk-signer.jar
#   JAVA                java binary                 (default: java)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

VERSION="${KOREADER_VERSION:-2026.07.1}"
ABI="${KOREADER_ABI:-android-arm}"
PKG=org.koreader.launcher
OUT="$WORK/koreader-home.apk"
DEC="$WORK/koreader-dec"

DO_INSTALL=0
SRC=""
for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=1 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) SRC="$arg" ;;
  esac
done
[ "$DO_INSTALL" = "1" ] && SRC="${SRC:-}"

ensure_work

# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------
find_jar() {                      # find_jar ENV_VAR filename
  local env="$1" name="$2"
  local v="${!env:-}"
  if [ -n "$v" ]; then [ -f "$v" ] || die "$env=$v does not exist"; echo "$v"; return 0; fi
  local f
  for f in "$REPO_ROOT/tools/$name" "$REPO_ROOT/../tools/$name" "$WORK/$name"; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}
APKTOOL="$(find_jar APKTOOL apktool.jar || true)"
SIGNER="$(find_jar UBER_APK_SIGNER uber-apk-signer.jar || true)"
JAVA="${JAVA:-java}"
need_cmd "$JAVA"
need_cmd unzip
AAPT2="$(find_aapt2)"
[ -n "$AAPT2" ] || die "aapt2 not found (Android SDK build-tools) - needed to verify the result"
[ -n "$APKTOOL" ] || die "apktool.jar not found. Set APKTOOL=/path/to/apktool.jar
   Get it from https://github.com/iBotPeaches/Apktool/releases"
[ -n "$SIGNER" ] || die "uber-apk-signer.jar not found. Set UBER_APK_SIGNER=/path/to/uber-apk-signer.jar
   Get it from https://github.com/patrickfav/uber-apk-signer/releases"

home_count() { "$AAPT2" dump xmltree --file AndroidManifest.xml "$1" 2>/dev/null \
                 | grep -c 'category.HOME' || true; }
apk_version() { "$AAPT2" dump badging "$1" 2>/dev/null \
                 | sed -n "s/^package:.*versionName='\([^']*\)'.*/\1/p" | head -1; }
apk_signer() {
  local a; a="$(dirname "$AAPT2")/apksigner"
  [ -x "$a" ] || { echo "(apksigner not found)"; return 0; }
  "$a" verify --print-certs "$1" 2>/dev/null | sed -n 's/^Signer #1 certificate DN: //p' | head -1
}

# ---------------------------------------------------------------------------
# obtain the official APK
# ---------------------------------------------------------------------------
if [ -z "$SRC" ]; then
  SRC="$WORK/koreader-official-$VERSION.apk"
  if [ -f "$SRC" ]; then
    info "using cached $SRC"
  else
    URL="https://github.com/koreader/koreader/releases/download/v$VERSION/koreader-$ABI-v$VERSION.apk"
    info "downloading $URL"
    need_cmd curl
    curl -sSL --max-time 600 -o "$SRC" "$URL" || die "download failed"
  fi
fi
[ -f "$SRC" ] || die "no such file: $SRC"

step "source APK"
printf '    %s\n' "$SRC"
printf '    size    %s bytes\n' "$(stat -c%s "$SRC")"
printf '    version %s\n' "$(apk_version "$SRC")"
printf '    signer  %s\n' "$(apk_signer "$SRC")"
printf '    HOME categories: %s\n' "$(home_count "$SRC")"

# If a future release starts declaring HOME itself, there is nothing to do -
# and re-signing anyway would only cost the ability to update normally.
if [ "$(home_count "$SRC")" != "0" ]; then
  ok "this APK already declares HOME - no patch needed"
  cp "$SRC" "$OUT"
  info "copied to $OUT (still official-signed)"
else
  # -------------------------------------------------------------------------
  # decode, patch the manifest, rebuild, sign
  # -------------------------------------------------------------------------
  step "decoding with apktool"
  rm -rf "$DEC"
  "$JAVA" -jar "$APKTOOL" d -f -o "$DEC" "$SRC" >"$WORK/apktool-d.log" 2>&1 \
    || { tail -20 "$WORK/apktool-d.log" | sed 's/^/    /'; die "apktool decode failed"; }
  MAN="$DEC/AndroidManifest.xml"
  [ -f "$MAN" ] || die "no AndroidManifest.xml in the decoded tree"
  ok "decoded"

  step "patching MainActivity's MAIN intent-filter"
  python3 - "$MAN" <<'PY'
import re, sys
path = sys.argv[1]
lines = open(path, encoding='utf-8').read().splitlines(keepends=True)

def ind(s): return len(s) - len(s.lstrip())

# locate MainActivity
start = None
for i, l in enumerate(lines):
    if l.lstrip().startswith('<activity') and 'MainActivity' in l:
        start = i; break
if start is None:
    sys.exit('FATAL: no <activity ... MainActivity ...> in the manifest')
a_ind = ind(lines[start])

# find its closing tag
end = None
for j in range(start + 1, len(lines)):
    t = lines[j].strip()
    if t.startswith('</activity>') and ind(lines[j]) == a_ind:
        end = j; break
if end is None:
    sys.exit('FATAL: could not find the end of the MainActivity element')

# within it, find the intent-filter that carries action MAIN
f_start = f_end = None
k = start + 1
while k < end:
    t = lines[k].strip()
    if t.startswith('<intent-filter'):
        f_ind = ind(lines[k]); fi = k; k += 1
        has_main = False
        while k < end and not (lines[k].strip().startswith('</intent-filter>') and ind(lines[k]) == f_ind):
            if 'android.intent.action.MAIN' in lines[k]: has_main = True
            k += 1
        if has_main:
            f_start, f_end, f_ind_used = fi, k, f_ind
            break
    k += 1
if f_start is None:
    sys.exit('FATAL: MainActivity has no intent-filter with android.intent.action.MAIN')

body = lines[f_start:f_end]
if any('android.intent.category.HOME' in l for l in body):
    print('  HOME already present in that filter - nothing to do')
    sys.exit(0)

# match the indentation of the existing <category> lines, else step in once
cat_lines = [l for l in body if l.strip().startswith('<category')]
ci = ind(cat_lines[0]) if cat_lines else ind(lines[f_start]) + 4
pad = ' ' * ci
add = [f'{pad}<category android:name="android.intent.category.HOME"/>\n',
       f'{pad}<category android:name="android.intent.category.DEFAULT"/>\n']
lines[f_end:f_end] = add
open(path, 'w', encoding='utf-8').writelines(lines)
print(f'  added HOME + DEFAULT to the MAIN intent-filter (indent {ci})')
PY

  step "rebuilding"
  "$JAVA" -jar "$APKTOOL" b "$DEC" -o "$WORK/koreader-home-unsigned.apk" \
      >"$WORK/apktool-b.log" 2>&1 \
    || { tail -20 "$WORK/apktool-b.log" | sed 's/^/    /'; die "apktool build failed"; }
  ok "rebuilt"

  step "signing"
  cp "$WORK/koreader-home-unsigned.apk" "$OUT"
  "$JAVA" -jar "$SIGNER" -a "$OUT" --overwrite >"$WORK/sign.log" 2>&1 \
    || { tail -20 "$WORK/sign.log" | sed 's/^/    /'; die "signing failed"; }
  ok "signed"
fi

# ---------------------------------------------------------------------------
# verify - never trust the patch, check the result
# ---------------------------------------------------------------------------
step "verify"
hc="$(home_count "$OUT")"
[ "$hc" != "0" ] || die "the result still declares no HOME category - do NOT install it"
ok "declares HOME ($hc occurrence(s))"

srcv="$(apk_version "$SRC")"; outv="$(apk_version "$OUT")"
printf '    version : %s -> %s\n' "$srcv" "$outv"
[ "$srcv" = "$outv" ] || warn "version changed during the rebuild - check that"
printf '    signer  : %s\n' "$(apk_signer "$OUT")"
printf '    size    : %s bytes\n' "$(stat -c%s "$OUT")"

cat <<EOF

Ready: $OUT

Install it with:

    adb uninstall $PKG          # the debug signature differs from the official one
    adb install $OUT

That uninstall deletes KOReader's APP data. Books and reading positions live on
the user partition (/storage/sdcard1/koreader) and are not affected.

Then 30-debloat.sh will find a real HOME declarer and let you proceed.
EOF

if [ "$DO_INSTALL" = "1" ]; then
  require_adb
  step "installing"
  if adb_ shell "pm path $PKG" 2>/dev/null | grep -q package:; then
    adb_ uninstall "$PKG" >/dev/null 2>&1 || warn "uninstall failed (continuing)"
  fi
  adb_ install -r "$OUT" || die "install failed"
  ok "installed"
fi
