#!/usr/bin/env bash
# Package a finished macOS build (scripts/macos/setup-and-build.sh) into a self-contained
# Amarok.app and a .dmg. Nothing in the result refers to Homebrew or ~/kde-prefix.
# Usage: scripts/macos/package.sh [app|dmg|all]
#   SIGN_ID="Developer ID Application: ..."   code-signing identity (default: ad-hoc "-")
#   NOTARY_PROFILE=name                        notarytool keychain profile; notarizes the dmg when set
set -euo pipefail

PREFIX="${KF_PREFIX:-$HOME/kde-prefix}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${AMAROK_BUILD:-$REPO/build-macos}"
OUT="${AMAROK_DIST:-$REPO/dist-macos}"
APP="$OUT/Amarok.app"
SIGN_ID="${SIGN_ID:--}"
BREW="$(brew --prefix)"
QTBASE="$(brew --prefix qtbase)"
QTQML="$(brew --prefix qtdeclarative)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$BUILD/bin/amarok.app/Contents/Info.plist" 2>/dev/null || echo dev)"

# GStreamer: audio-only subset of what Homebrew ships (the full set is ~280 plugins, most are video).
GST_PLUGINS="coreelements typefindfunctions playback audioconvert audioresample volume osxaudio applemedia
  autodetect audioparsers audiofx equalizer level spectrum replaygain ogg vorbis flac opus opusparse
  mpg123 lame faad faac id3demux id3tag apetag isomp4 wavparse aiff matroska musepack dsd taglib libav"

copy_dir() { mkdir -p "$2"; ditto "$1" "$2"; }

app() {
  [ -d "$BUILD/bin/amarok.app" ] || { echo "no build in $BUILD: run setup-and-build.sh first"; exit 1; }
  echo "== assembling $APP"
  rm -rf "$APP"
  local C="$APP/Contents"
  mkdir -p "$C/MacOS" "$C/Frameworks" "$C/PlugIns" "$C/Resources"

  # -- executables; the scanner must sit next to the main binary, which is where Amarok looks for it
  cp "$BUILD/bin/amarok.app/Contents/MacOS/amarok" "$C/MacOS/amarok-bin"
  cp "$BUILD/bin/amarokcollectionscanner.app/Contents/MacOS/amarokcollectionscanner" "$C/MacOS/"
  cp "$BUILD/bin/amarok_afttagger.app/Contents/MacOS/amarok_afttagger" "$C/MacOS/"
  cp "$BREW/bin/dbus-daemon" "$C/MacOS/"
  cp "$BREW/opt/gstreamer/libexec/gstreamer-1.0/gst-plugin-scanner" "$C/MacOS/"
  cp -R "$BUILD/bin/amarok.app/Contents/Resources/." "$C/Resources/"

  # -- Amarok libraries, embedded database, KF6 and Amarok plugins
  for f in "$PREFIX"/lib/libamarok*.1.dylib "$PREFIX"/lib/libamarokpud.dylib \
           "$PREFIX/lib/libmariadbd.19.dylib" "$PREFIX/lib/libmariadb.3.dylib"; do
    cp -L "$f" "$C/Frameworks/"
  done
  copy_dir "$PREFIX/lib/plugins" "$C/PlugIns"
  rm -f "$C"/PlugIns/kcm_* # configuration modules that need the (absent) KDE system settings host

  # KIO starts its out-of-process workers from a libexec directory next to the KIO library
  mkdir -p "$C/Frameworks/libexec/kf6"
  cp "$PREFIX/libexec/kf6/kioworker" "$C/Frameworks/libexec/kf6/"

  # -- Qt plugins Amarok needs
  for d in platforms styles imageformats iconengines tls networkinformation generic; do
    [ -d "$QTBASE/share/qt/plugins/$d" ] && copy_dir "$QTBASE/share/qt/plugins/$d" "$C/PlugIns/$d"
  done
  for d in iconengines imageformats; do
    [ -d "$(brew --prefix qtsvg)/share/qt/plugins/$d" ] && copy_dir "$(brew --prefix qtsvg)/share/qt/plugins/$d" "$C/PlugIns/$d"
  done

  # -- QML: Qt's own modules (what the applets import) plus Kirigami and Amarok's
  copy_dir "$PREFIX/lib/qml" "$C/Resources/qml"
  for m in QtQuick QtQml QtCore QtNetwork; do
    [ -d "$QTQML/share/qt/qml/$m" ] && copy_dir "$QTQML/share/qt/qml/$m" "$C/Resources/qml/$m"
  done
  find "$C/Resources/qml" \( -name '*.o' -o -name '*.prl' -o -name '*.qmltypes' -o -name '*.qmlc' \) -delete
  rm -rf "$C/Resources/qml/QtQuick/tooling"
  # Applets are loaded from the build tree's lib dir by their QML plugin entries
  for f in "$PREFIX"/lib/libamarok_context_applet_*.dylib "$BUILD"/bin/libamarok_context_applet_*.dylib \
           "$BUILD/bin/libqml_plugin.dylib" "$BUILD/bin/libampache_account_login.dylib"; do
    [ -f "$f" ] && cp -L "$f" "$C/Frameworks/" || true
  done

  # -- data: same layout as <prefix>/share, because Qt searches Contents/Resources like a data dir
  for d in amarok kpackage icons locale mime kf6 knotifications6 solid qlogging-categories6; do
    [ -d "$PREFIX/share/$d" ] && copy_dir "$PREFIX/share/$d" "$C/Resources/$d"
  done
  mkdir -p "$C/Resources/mysql"
  copy_dir "$PREFIX/share/english" "$C/Resources/mysql/english"
  copy_dir "$PREFIX/share/charsets" "$C/Resources/mysql/charsets"
  # only the Breeze theme is used; drop the dark variant's duplicate and other themes
  find "$C/Resources/icons" -mindepth 1 -maxdepth 1 ! -name 'breeze' ! -name 'breeze-dark' -exec rm -rf {} +

  # -- GStreamer plugins
  mkdir -p "$C/PlugIns/gstreamer"
  for p in $GST_PLUGINS; do
    f="$BREW/lib/gstreamer-1.0/libgst$p.dylib"
    [ -f "$f" ] && cp -L "$f" "$C/PlugIns/gstreamer/" || echo "   (no gst plugin $p)"
  done

  # -- without this Qt also searches its build-time prefix (Homebrew) and loads a second copy of itself
  printf '[Paths]\nPlugins = PlugIns\nQml2Imports = Resources/qml\n' > "$C/Resources/qt.conf"

  # -- launcher (the bundle executable): private D-Bus session, then the real binary
  install -m 755 "$REPO/scripts/macos/launcher.sh" "$C/MacOS/Amarok"

  # -- Info.plist: the build's template has no identifier or version
  cp "$BUILD/bin/amarok.app/Contents/Info.plist" "$C/Info.plist"
  local P=/usr/libexec/PlistBuddy
  $P -c "Set :CFBundleExecutable Amarok" -c "Set :CFBundleName Amarok" \
     -c "Set :CFBundleIdentifier org.kde.amarok" -c "Set :CFBundleShortVersionString $VERSION" \
     -c "Set :CFBundleVersion $VERSION" -c "Set :CFBundleIconFile amarok_SRCS.icns" \
     -c "Delete :LSRequiresCarbon" -c "Delete :CFBundleSignature" \
     -c "Add :LSMinimumSystemVersion string 13.0" -c "Add :NSHighResolutionCapable bool true" \
     -c "Add :LSApplicationCategoryType string public.app-category.music" \
     -c "Add :NSAppleEventsUsageDescription string Amarok" "$C/Info.plist" >/dev/null 2>&1 || true

  echo "== making it self-contained"
  python3 "$REPO/scripts/macos/bundle_fix.py" "$APP" "$PREFIX/lib" "$BREW/lib" "$QTBASE/lib" \
    "$(brew --prefix qtsvg)/lib" "$(brew --prefix qtdeclarative)/lib" "$(brew --prefix qtmultimedia)/lib" \
    "$(brew --prefix qtwayland 2>/dev/null)/lib"

  sign
  # without this Notification Center can keep showing a generic icon for a freshly built bundle
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "$APP" || true
  echo "== $APP ($(du -sh "$APP" | cut -f1))"
}

sign() {
  echo "== signing with '${SIGN_ID}'"
  local opts=(--force --sign "$SIGN_ID")
  [ "$SIGN_ID" != "-" ] && opts+=(--options runtime --timestamp)
  # innermost first: every Mach-O file, then nested bundles (deepest first), then the app itself
  while IFS= read -r f; do
    file -b "$f" | grep -q Mach-O && { codesign "${opts[@]}" "$f" 2>&1 | grep -v "replacing existing signature" || true; }
  done < <(find "$APP/Contents" -type f ! -path '*.framework/Versions/*/Resources/*' -o -type f -path '*/Helpers/*')
  while IFS= read -r b; do codesign "${opts[@]}" "$b" 2>&1 | grep -v "replacing existing signature" || true
  done < <(find "$APP/Contents" -type d \( -name '*.app' -o -name '*.framework' \) | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)
  codesign "${opts[@]}" "$APP"
  codesign --verify --deep --strict "$APP" && echo "   signature OK"
}

dmg() {
  [ -d "$APP" ] || app
  local img="$OUT/Amarok-$VERSION-$(uname -m).dmg" stage="$OUT/dmg-stage"
  echo "== building $img"
  rm -rf "$stage" "$img"; mkdir -p "$stage"
  ditto "$APP" "$stage/Amarok.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "Amarok" -srcfolder "$stage" -ov -format UDZO "$img" >/dev/null
  rm -rf "$stage"
  [ "$SIGN_ID" != "-" ] && codesign --force --sign "$SIGN_ID" --timestamp "$img"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$img" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$img"
  fi
  echo "== $img ($(du -sh "$img" | cut -f1))"
}

case "${1:-all}" in
  app) app ;; dmg) dmg ;; all) app; dmg ;;
  *) echo "usage: $0 [app|dmg|all]"; exit 1 ;;
esac
