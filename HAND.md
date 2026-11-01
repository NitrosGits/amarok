# HAND.md: macOS build handoff for Amarok

Goal: build this Amarok checkout (Qt6/KF6 port, branch `master`) natively on macOS (Apple Silicon, Qt 6.12 from Homebrew), with the **embedded MariaDB** (`WITH_EMBEDDED_DB=ON`), and keep a script that reproduces the whole setup on other Macs.

Status snapshot is at the bottom ("Where things stand"). Update it when you continue.

## Layout / key files

| Path | Purpose |
|---|---|
| `scripts/macos/setup-and-build.sh` | Deploy script: `deps` -> `kf6` -> `mariadb` -> `patch` -> `amarok` (or `all`). Idempotent; KF6 frameworks are tracked by `~/kde-prefix/.built-<name>` markers. **Not yet run end-to-end from a clean machine.** |
| `scripts/macos/patches/0001-macos-qt6-port.patch` | Qt6 fixes for Amarok's macOS-only sources (`App.cpp`, `app_mac.cpp`, `src/mac/*`). `setup-and-build.sh amarok` (or `patch`) applies it automatically and idempotently. If you fix more source files, regenerate it with `git diff -- src > scripts/macos/patches/0001-macos-qt6-port.patch` (or add a 0002). |
| `scripts/macos/progress.sh` | Progress/error summary for the Amarok and MariaDB builds (`-w` to watch). |
| `scripts/macos/qt-private.cmake` | Passed as `CMAKE_PROJECT_INCLUDE` to every KF6 build. |
| `~/kde-prefix` | Install prefix for KF6 (and, in progress, MariaDB). |
| `~/kde-src/<framework>` | KF6 source clones, tag `v6.31.0`. `~/kde-src/mariadb` = MariaDB 10.11.13. |
| `build-macos/` | Amarok build dir (Ninja). Logs: `~/amarok-build.log`, `~/mariadb-build.log`, `~/kf6-build.log`. |

Amarok configure command (works):

```bash
PATH="/opt/homebrew/opt/bison/bin:$PATH" cmake -S . -B build-macos -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$HOME/kde-prefix;$(brew --prefix qt);$(brew --prefix)" \
  -DWITH_IPOD=OFF -DWITH_LASTFM=OFF -DWITH_EMBEDDED_DB=OFF -DKF_IGNORE_PLATFORM_CHECK=ON
```

(`-DWITH_EMBEDDED_DB=OFF` was used to get a first compile. MariaDB with `libmariadbd` is now installed in `~/kde-prefix`, so switch to `ON` plus `-DMYSQLCONFIG_EXECUTABLE=$HOME/kde-prefix/bin/mysql_config`.)

## Problems hit and fixes (in order)

1. **KF6 not in Homebrew.** The old `KDE-mac/kde` tap is gone (404). Fix: build ~39 KF6 frameworks from `invent.kde.org/frameworks/<name>` into `~/kde-prefix` via the script.
2. **gperf `register` error (kcodecs), C++17.** Fix: `-DCMAKE_CXX_FLAGS=-Wno-register`.
3. **`Qt6::GuiPrivate` target not found (kcolorscheme).** Fix: `qt-private.cmake` does `find_package(Qt6GuiPrivate ...)` etc. It must be guarded with `if(CMAKE_CXX_COMPILER_LOADED)`, otherwise `extra-cmake-modules` (LANGUAGES NONE) fails in FindThreads.
4. **KF 6.10.0 does not compile against Qt 6.12** (karchive `QString::arg(QFlags)` errors). Fix: use `KF_TAG=v6.31.0`. A tag mix in one prefix is unsafe, so the prefix was wiped and rebuilt.
5. **kdoctools needs DocBook.** Fix: `brew install docbook docbook-xsl` (kdoctools already searches the Homebrew paths).
6. **solid needs Bison >= 3.0** (macOS ships 2.3). Fix: `brew install bison flex` and prepend `/opt/homebrew/opt/bison/bin` to `PATH`. After a failed attempt, delete that project's `build/` dir, because CMake caches `BISON_EXECUTABLE=/usr/bin/bison`.
7. **kglobalaccel: "platform 'Darwin' not supported".** Fix: `-DKF_IGNORE_PLATFORM_CHECK=ON`, plus `-DWITH_X11=OFF` (it otherwise includes `private/qtx11extras_p.h`). It builds fine after that.
8. **kiconthemes needs `KF6BreezeIcons`.** Fix: add `breeze-icons` before it in the build order, with `-DWITH_ICON_GENERATION=OFF` (the generator needs python `lxml`).
9. **Ordering:** `kio` must build before `kparts`, and `kirigami` before `kcmutils`. The `FRAMEWORKS` array in the script is now in a working order.
10. **Embedded DB: Homebrew `mariadb` ships no `libmariadbd`**, and `libgpod` does not exist in Homebrew (so `WITH_IPOD=OFF`; `WITH_LASTFM=OFF` also set, needs a Qt6 liblastfm fork). `Mygpo-qt6` is also absent (optional, gpodder service is skipped).
11. **Amarok's macOS-only sources were never ported to Qt6** (`src/app_mac.cpp`, `src/mac/GrowlInterface.{h,cpp}`, `src/mac/MacSystemNotify.{h,mm}`). Fixes are captured in `scripts/macos/patches/0001-macos-qt6-port.patch` (also applied in this checkout, uncommitted); `App.cpp` additionally needed `setenv("PATH", path.constData(), 1)`. They were: `class X : public QObject` (private inheritance broke `connect`), `#include <KLocalizedString>`, `QStringLiteral`/`QLatin1Char` instead of raw literals (Amarok defines `QT_NO_CAST_FROM_ASCII`), and `QPixmap::toMacCGImageRef()` (removed in Qt6) replaced by PNG-encoding via `QBuffer` + `[NSImage initWithData:]`.

## Update: BUILD SUCCEEDED

`scripts/macos/setup-and-build.sh amarok` completed 549/549 with embedded DB ON; `build-macos/bin/amarok.app/Contents/MacOS/amarok --version` prints `amarok 3.3.3-git`. Extra fixes found on the way: pass `-DCMAKE_PREFIX_PATH=...` explicitly (the env-var form with `;` is ignored), and add `-L/opt/homebrew/lib -L~/kde-prefix/lib` to the linker flags (gstreamer link failure). NOT yet done: launching the GUI and testing playback and the embedded DB, bundling for deployment (macdeployqt, rpaths, a `.dmg`), the clean-machine run of the full script, and committing.

## Update: APP LAUNCHES AND LOOKS RIGHT

`scripts/macos/setup-and-build.sh run` starts Amarok; the main window, playback bar, sidebar icons and Context applets (6) all show, and all 17 plugins load. Confirmed by the user from screenshots. Problems hit after the build, and their fixes:

12. **Crash in `TrayIcon::TrayIcon`** (call through a null pointer): `qt_mac_set_dock_menu` is a private Qt5 symbol, gone in Qt6. The linker lets it through as undefined. Fix: `contextMenu()->setAsDockMenu()` (in `src/TrayIcon.cpp`).
13. **"Amarok could not find any plugins"**: only Qt library paths are searched. Fix: install into `~/kde-prefix` and launch with `QT_PLUGIN_PATH=~/kde-prefix/lib/plugins`. Do NOT point `QT_PLUGIN_PATH` at the build dir only: that hides the KF6 plugins and gives "Unable to create KIO worker. Unknown protocol 'file'" and the kirigami QML error.
14. **Installed libs had `/opt/homebrew/Cellar/extra-cmake-modules/...` as install names** (plugins failed with "Library not loaded"). Cause: Amarok was configured without `CMAKE_INSTALL_PREFIX`. Fix: pass `-DCMAKE_INSTALL_PREFIX=$PREFIX`, rebuild, `cmake --install`.
15. **Playback controls / toolbar / context applets missing, `SvgHandler ... at ""` in the log**: `QStandardPaths` on macOS ignores `XDG_DATA_DIRS`, so `amarok/images/...` and `kpackage/amarok` are not found. Fix (`link_data` in the script): symlink `share/amarok/{data,icons,images,scriptconsole}` into `~/Library/Application Support/amarok/` and `share/kpackage/amarok` into `~/Library/Application Support/kpackage/`. A cleaner long-term fix is to load these from the app bundle's Resources.
16. **Sidebar icons blank**: Qt on macOS has no icon theme set (`QIcon::themeName()` is empty), so only `drive-harddisk` and `folder` resolved. Fix in `App::App` (macOS block): add `XDG_DATA_DIRS` entries (`/icons`, `/amarok/icons`) to the icon search paths and `QIcon::setThemeName("breeze")` if empty.
17. **24px Breeze icons**: `breeze-icons` was built with `WITH_ICON_GENERATION=OFF`. Now ON, with a venv (`$PREFIX/.icon-venv`, has `lxml`) passed via `-DPython_EXECUTABLE`. The variable name is `Python_EXECUTABLE`, not `Python3_EXECUTABLE`.
18. **No D-Bus session bus on macOS**: Homebrew's `dbus` wants launchd. The script's `run` starts `dbus-daemon` with a copy of `session.conf` listening on a unix socket in `$TMPDIR/amarok-dbus/`.

The patch `scripts/macos/patches/0001-macos-qt6-port.patch` now covers 8 source files (adds `App.cpp` icon setup and `TrayIcon.cpp`). Regenerate with `git diff -- src > scripts/macos/patches/0001-macos-qt6-port.patch`.

## Where things stand

- KF6 (39 frameworks), MariaDB 10.11 embedded, Amarok build and install: done. `setup-and-build.sh` now: icon venv, `CMAKE_INSTALL_PREFIX`, `cmake --install`, `link_data`, and a `run` command. `link` and `run` are new subcommands.
- Remaining log noise, not yet investigated: `Table 'mysql.servers' doesn't exist` (embedded MariaDB has no system tables), missing `magnatune_*` tables (maybe first run), QML warnings (`AppletToolbar.qml:102 Cannot assign to non-existent property "contextRoot"`, binding loop in `Main.qml`, recursive GridLayout in the Current Track applet), no `kglobalaccel` service (global shortcuts).
- Not done:
  1. Test actual playback (GStreamer) and collection scanning with the embedded DB.
  2. Bundle properly for distribution (`macdeployqt`, rpaths, load data from the bundle instead of `~/Library` symlinks, `.dmg`).
  3. Run the full script from a clean machine. The new `link`/`run`/icon-venv parts were only tested incrementally.
  4. Commit (nothing is committed yet).

## Gotchas

- Always rerun with a fresh `build/` dir for a project after changing PATH or flags that affect cached tools.
- Set `PATH="/opt/homebrew/opt/bison/bin:$PATH"` for any MariaDB or KF6 solid/ktexteditor-style build.
- Downloads in this session were done only with the user's approval (KF6 from invent.kde.org, MariaDB from GitHub).
