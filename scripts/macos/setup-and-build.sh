#!/usr/bin/env bash
# Build Amarok on macOS (Apple Silicon/Intel). Idempotent: re-run to resume.
# Usage: scripts/macos/setup-and-build.sh [prereqs|deps|kf6|mariadb|patch|amarok|link|run|all]
set -euo pipefail

KF_TAG="${KF_TAG:-v6.31.0}"
PREFIX="${KF_PREFIX:-$HOME/kde-prefix}"
SRC="${KF_SRC:-$HOME/kde-src}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${AMAROK_BUILD:-$REPO/build-macos}"
# Homebrew may not be installed yet (the prereqs stage installs it); pick it up from its default prefixes.
if ! command -v brew >/dev/null 2>&1; then
  for p in /opt/homebrew/bin /usr/local/bin; do [ -x "$p/brew" ] && PATH="$p:$PATH"; done
fi
if command -v brew >/dev/null 2>&1; then BREW="$(brew --prefix)"; QT="$(brew --prefix qt)"; else BREW=""; QT=""; fi
JOBS="$(sysctl -n hw.ncpu)"

# KF6 frameworks in dependency order (includes transitive deps of what Amarok needs).
FRAMEWORKS=(
  extra-cmake-modules ki18n kcodecs kconfig kcoreaddons kdbusaddons kwidgetsaddons
  kguiaddons kcolorscheme kitemviews kconfigwidgets kauth karchive kcrash
  kwindowsystem kdoctools solid threadweaver kglobalaccel breeze-icons kiconthemes knotifications
  kpackage kservice kjobwidgets kbookmarks kcompletion kitemmodels kxmlgui kio kparts
  sonnet ktextwidgets syntax-highlighting kirigami kcmutils ktexteditor
  kstatusnotifieritem kdnssd
)

# A clean macOS has neither the Xcode command-line tools nor Homebrew. Both installers need an admin
# account; Homebrew's NONINTERACTIVE mode additionally needs sudo without a password prompt
# (or run this stage once from an interactive terminal).
prereqs() {
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "== installing the Xcode command-line tools"
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    local clt; clt="$(softwareupdate -l 2>/dev/null | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | sort -V | tail -1)"
    [ -n "$clt" ] || { echo "could not find the Command Line Tools update; run: xcode-select --install"; exit 1; }
    sudo softwareupdate -i "$clt" --verbose
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  fi
  if ! command -v brew >/dev/null 2>&1; then
    echo "== installing Homebrew"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    for p in /opt/homebrew/bin /usr/local/bin; do [ -x "$p/brew" ] && PATH="$p:$PATH"; done
  fi
  command -v brew >/dev/null 2>&1 || { echo "Homebrew is still not on PATH"; exit 1; }
  BREW="$(brew --prefix)"; QT="$(brew --prefix qt)"
  echo "== prereqs done: $(xcode-select -p), brew at $BREW"
}

deps() {
  [ -n "$BREW" ] || { echo "Homebrew not found: run '$0 prereqs' first"; exit 1; }
  brew install cmake ninja pkgconf qt extra-cmake-modules taglib gstreamer \
    mariadb libmtp fftw libgcrypt libxml2 googletest glib gdk-pixbuf curl \
    openssl@3 gettext libarchive libxslt bison flex docbook-xsl shared-mime-info dbus
  # kdoctools needs URI::Escape, which not every Perl install has (CI runners do not)
  perl -MURI::Escape -e1 2>/dev/null || PERL_MM_USE_DEFAULT=1 cpan -T URI::Escape >/dev/null 2>&1 \
    || sudo env PERL_MM_USE_DEFAULT=1 cpan -T URI::Escape >/dev/null
  perl -MURI::Escape -e1 || { echo "Perl module URI::Escape is missing"; exit 1; }
}

# breeze-icons generates the 24px icon set with a python script that needs lxml.
icon_python() {
  local venv="$PREFIX/.icon-venv"
  [ -x "$venv/bin/python" ] || python3 -m venv "$venv"
  "$venv/bin/python" -c 'import lxml' 2>/dev/null || "$venv/bin/pip" install -q lxml
  echo "$venv/bin/python"
}

kf6() {
  local PY; PY="$(icon_python)"
  export PATH="$BREW/opt/bison/bin:$BREW/opt/flex/bin:$PATH"
  mkdir -p "$SRC" "$PREFIX"
  # Homebrew's libxml2/libxslt, not the SDK's copies: the SDK ones put its usr/include ahead of libc++'s headers
  export CMAKE_PREFIX_PATH="$PREFIX:$QT:$BREW/opt/libxml2:$BREW/opt/libxslt:$BREW:$BREW/opt/gettext:$BREW/opt/libarchive"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$BREW/opt/libxml2/lib/pkgconfig:$BREW/opt/libxslt/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  for f in "${FRAMEWORKS[@]}"; do
    [ -f "$PREFIX/.built-$f" ] && { echo "== $f (done)"; continue; }
    echo "== building $f"
    [ -d "$SRC/$f" ] || git clone --depth 1 --branch "$KF_TAG" "https://invent.kde.org/frameworks/$f.git" "$SRC/$f"
    cmake -S "$SRC/$f" -B "$SRC/$f/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_TESTING=OFF -DBUILD_QCH=OFF \
      -DBUILD_DESIGNERPLUGIN=OFF -DBUILD_PYTHON_BINDINGS=OFF -DKF_IGNORE_PLATFORM_CHECK=ON -DWITH_X11=OFF -DWITH_ICON_GENERATION=ON -DPython_EXECUTABLE="$PY" -DCMAKE_CXX_FLAGS=-Wno-register -DCMAKE_PROJECT_INCLUDE="$REPO/scripts/macos/qt-private.cmake"
    cmake --build "$SRC/$f/build" -j"$JOBS"
    cmake --install "$SRC/$f/build"
    touch "$PREFIX/.built-$f"
  done
}

# Apply macOS/Qt6 source fixes (scripts/macos/patches/*.patch) before building.
# Idempotent: skips patches that are already applied; fails if one only half-applies.
patch_source() {
  local p
  for p in "$REPO"/scripts/macos/patches/*.patch; do
    [ -f "$p" ] || continue
    if git -C "$REPO" apply --check -R "$p" 2>/dev/null; then
      echo "== patch already applied: $(basename "$p")"
    elif git -C "$REPO" apply --check "$p" 2>/dev/null; then
      echo "== applying patch: $(basename "$p")"
      git -C "$REPO" apply "$p"
    else
      echo "ERROR: $(basename "$p") neither applies nor is already applied; resolve manually" >&2
      return 1
    fi
  done
}

# MariaDB 10.11 built with the embedded server (libmariadbd); Homebrew's bottle lacks it.
# 10.11 is the last LTS line that still supports WITH_EMBEDDED_SERVER.
mariadb() {
  [ -f "$PREFIX/.built-mariadb" ] && { echo "== mariadb (done)"; return; }
  export PATH="$BREW/opt/bison/bin:$PATH"
  mkdir -p "$SRC" "$PREFIX"
  [ -d "$SRC/mariadb" ] || git clone --depth 1 --branch "${MARIADB_TAG:-mariadb-10.11.13}" https://github.com/MariaDB/server.git "$SRC/mariadb"
  git -C "$SRC/mariadb" submodule update --init --depth 1
  # 10.11 reads one element past a 1-element argv in mysql_read_default_options(), which
  # segfaults on macOS arm64 (works on Linux by stack luck). Idempotent patch application.
  local mp
  for mp in "$REPO"/scripts/macos/patches/mariadb/*.patch; do
    [ -f "$mp" ] || continue
    if git -C "$SRC/mariadb" apply --check -R "$mp" 2>/dev/null; then
      echo "== mariadb patch already applied: $(basename "$mp")"
    else
      echo "== applying mariadb patch: $(basename "$mp")"
      git -C "$SRC/mariadb" apply "$mp"
    fi
  done
  cmake -S "$SRC/mariadb" -B "$SRC/mariadb/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DWITH_EMBEDDED_SERVER=ON -DWITH_UNIT_TESTS=OFF \
    -DPLUGIN_TOKUDB=NO -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO \
    -DPLUGIN_CONNECT=NO -DWITH_WSREP=OFF -DWITH_ZLIB=bundled -DWITH_SSL=system -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
  cmake --build "$SRC/mariadb/build" --target install -j"$JOBS"
  touch "$PREFIX/.built-mariadb"
}

amarok() {
  patch_source
  export PATH="$BREW/opt/bison/bin:$PATH"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$BREW/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  cmake -S "$REPO" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$PREFIX;$QT;$BREW" -DECM_DIR="$BREW/share/ECM/cmake" -DWITH_IPOD=OFF -DWITH_LASTFM=OFF \
    -DWITH_EMBEDDED_DB=ON -DMYSQLCONFIG_EXECUTABLE="$PREFIX/bin/mysql_config" \
    -DKF_IGNORE_PLATFORM_CHECK=ON \
    -DCMAKE_BUILD_RPATH="$PREFIX/lib;$BREW/lib" -DCMAKE_INSTALL_RPATH="$PREFIX/lib;$BREW/lib" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$BREW/lib -L$PREFIX/lib" -DCMAKE_EXE_LINKER_FLAGS="-L$BREW/lib -L$PREFIX/lib" \
    -DCMAKE_MODULE_LINKER_FLAGS="-L$BREW/lib -L$PREFIX/lib" ${AMAROK_CMAKE_ARGS:-}
  cmake --build "$BUILD" -j"$JOBS"
  cmake --install "$BUILD"
  link_data
}

# Qt's QStandardPaths on macOS ignores XDG_DATA_DIRS, so Amarok (images, data, icons) and
# KPackage (context applets) cannot find their installed data. Link it into the places Qt does search.
link_data() {
  local app="$HOME/Library/Application Support"
  mkdir -p "$app/amarok" "$app/kpackage"
  for d in data icons images scriptconsole; do ln -sfn "$PREFIX/share/amarok/$d" "$app/amarok/$d"; done
  ln -sfn "$PREFIX/share/kpackage/amarok" "$app/kpackage/amarok"
}

# Launch the built app: Homebrew's dbus wants launchd, so run a private session bus on a socket.
run() {
  local d="${TMPDIR:-/tmp}/amarok-dbus"; mkdir -p "$d"
  if [ ! -S "$d/bus" ]; then
    sed "s#<listen>.*</listen>#<listen>unix:path=$d/bus</listen>#" "$BREW/share/dbus-1/session.conf" > "$d/session.conf"
    dbus-daemon --config-file="$d/session.conf" --fork
  fi
  DBUS_SESSION_BUS_ADDRESS="unix:path=$d/bus" QT_PLUGIN_PATH="$PREFIX/lib/plugins" \
    QML_IMPORT_PATH="$PREFIX/lib/qml" QML2_IMPORT_PATH="$PREFIX/lib/qml" XDG_DATA_DIRS="$PREFIX/share" \
    exec "$BUILD/bin/amarok.app/Contents/MacOS/amarok" "${@:2}"
}

case "${1:-all}" in
  prereqs) prereqs ;; deps) deps ;; kf6) kf6 ;; mariadb) mariadb ;; patch) patch_source ;; amarok) amarok ;; link) link_data ;; run) run "$@" ;;
  all) prereqs; deps; kf6; mariadb; amarok ;;
  *) echo "usage: $0 [prereqs|deps|kf6|mariadb|patch|amarok|link|run|all]"; exit 1 ;;
esac
