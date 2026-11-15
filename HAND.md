# HAND.md: macOS build handoff for Amarok

Goal: build this Amarok checkout (Qt6/KF6 port, branch `master`) natively on macOS (Apple Silicon, Qt 6.12 from Homebrew), with the **embedded MariaDB** (`WITH_EMBEDDED_DB=ON`), and keep a script that reproduces the whole setup on other Macs.

Status snapshot is at the bottom ("Where things stand"). Update it when you continue.

## Layout / key files

| Path | Purpose |
|---|---|
| `scripts/macos/setup-and-build.sh` | Deploy script: `deps` -> `kf6` -> `mariadb` -> `patch` -> `amarok` (or `all`). Idempotent; KF6 frameworks are tracked by `~/kde-prefix/.built-<name>` markers. Run end to end on a clean macOS VM (see STATUS UPDATE 5). |
| `scripts/macos/patches/mariadb/0001-client-argv-terminator.patch` | Patch for the MariaDB 10.11 source (see problem 19). Applied automatically by the `mariadb` stage. The old Amarok source patch `0001-macos-qt6-port.patch` was dropped (commit `850f4847c4`): the Qt6 fixes are now committed directly on `macos-qt6-port`, so the `patch` stage has nothing to do for Amarok itself. |
| `scripts/macos/progress.sh` | Progress/error summary for the Amarok and MariaDB builds (`-w` to watch). |
| `scripts/macos/qt-private.cmake` | Passed as `CMAKE_PROJECT_INCLUDE` to every KF6 build. |
| `~/kde-prefix` | Install prefix for KF6 (and, in progress, MariaDB). |
| `~/kde-src/<framework>` | KF6 source clones, tag `v6.31.0`. `~/kde-src/mariadb` = MariaDB 10.11.13. |
| `build-macos/` | Amarok build dir (Ninja). Logs: `~/amarok-build.log`, `~/mariadb-build.log`, `~/kf6-build.log`. |

Amarok configure command (works):

```bash
PATH="/opt/homebrew/opt/bison/bin:$PATH" cmake -S . -B build-macos -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$HOME/kde-prefix;$(brew --prefix qt);$(brew --prefix)" \
  -DWITH_IPOD=OFF -DWITH_LASTFM=OFF -DWITH_EMBEDDED_DB=ON -DMYSQLCONFIG_EXECUTABLE=$HOME/kde-prefix/bin/mysql_config \
  -DKF_IGNORE_PLATFORM_CHECK=ON
```
(Simplified: the script `scripts/macos/setup-and-build.sh amarok` is the source of truth, it also sets rpaths, linker `-L` flags and `CMAKE_INSTALL_PREFIX`.)

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

19. **Crash in `mysql_real_connect` at startup** (`strcmp` <- `get_defaults_options` <- `my_load_defaults` <- `mysql_read_default_options`, segfault on the main thread, Dock icon keeps bouncing, no window). Two causes. (a) A real bug in MariaDB 10.11 `sql-common/client.c`: `char *argv_buff[1]` is read one element past its end by `get_defaults_options()` (it skips `argv[0]` then scans for a NULL). Works on Linux by stack luck. Fix: `argv_buff[2]` plus `argv_buff[1]= 0`, in `scripts/macos/patches/mariadb/0001-client-argv-terminator.patch`, applied by the `mariadb` stage (the Windows build reuses the same patch). (b) Amarok's `MySqlEmbeddedStorage::init` built its server argv from a temporary (`databaseName().toUtf8().constData()` dangles) and never NULL-terminated it; the library keeps those pointers. Fix: static storage plus a terminator in `src/core-impl/storage/sql/mysqlestorage/MySqlEmbeddedStorage.cpp`. Fixing only (b) did NOT stop the crash; (a) was the root cause. Diagnose such crashes with `~/Library/Logs/DiagnosticReports/amarok-*.ips` (parse the JSON; the first frames name the library).

The patch `scripts/macos/patches/0001-macos-qt6-port.patch` now covers 8 source files (adds `App.cpp` icon setup and `TrayIcon.cpp`). Regenerate with `git diff -- src > scripts/macos/patches/0001-macos-qt6-port.patch`.

## Where things stand

- KF6 (39 frameworks), MariaDB 10.11 embedded, Amarok build and install: done. `setup-and-build.sh` now: icon venv, `CMAKE_INSTALL_PREFIX`, `cmake --install`, `link_data`, and a `run` command. `link` and `run` are new subcommands.
- Remaining log noise, not yet investigated: `Table 'mysql.servers' doesn't exist` (embedded MariaDB has no system tables), missing `magnatune_*` tables (maybe first run), QML warnings (`AppletToolbar.qml:102 Cannot assign to non-existent property "contextRoot"`, binding loop in `Main.qml`, recursive GridLayout in the Current Track applet), no `kglobalaccel` service (global shortcuts).
- Not done:
  1. Test actual playback (GStreamer) and collection scanning with the embedded DB.
  2. Bundle properly for distribution (`macdeployqt`, rpaths, load data from the bundle instead of `~/Library` symlinks, `.dmg`).
  3. (Done, see STATUS UPDATE 5: clean-machine run passed.)
  4. (Done: everything is committed and on the fork, see STATUS UPDATE 6.)

## Gotchas

- Always rerun with a fresh `build/` dir for a project after changing PATH or flags that affect cached tools.
- Set `PATH="/opt/homebrew/opt/bison/bin:$PATH"` for any MariaDB or KF6 solid/ktexteditor-style build.
- Downloads in this session were done only with the user's approval (KF6 from invent.kde.org, MariaDB from GitHub).

# Windows port (in progress)

Goal: build Amarok on Windows (Qt6/KF6) from the `windows-port` branch and get it running. Branch/worktree: `~/amarok-windows` (git worktree, branch `windows-port`, based on `master`, nothing committed yet). The main checkout `~/amarok` stays on `macos-qt6-port` (pushed to the fork `NitrosGits/amarok`, remote `fork`). Commits must not mention Claude or carry a Co-Authored-By trailer (user's instruction).

## VM
- Parallels VM **"Windows 11"** (ARM64, build 26300), 6 CPUs, 10 GB RAM (the Mac has only 18 GB). Currently **stopped**: `prlctl start "Windows 11"`.
- Run commands in it: `prlctl exec "Windows 11" --current-user powershell -NoProfile -ExecutionPolicy Bypass -File '\\Mac\winshare\X.ps1'` (omit `--current-user` to run as SYSTEM). Long jobs: run in background and log to the share, then poll the log.
- Shared folders (Parallels): `\\Mac\winshare` = `~/amarok-winshare` (scripts and logs; `install_craft.ps1` is KDE's script), `\\Mac\amarokwin` = `~/amarok-windows` (the Windows worktree). Only these two are shared, deliberately.
- Host disk is tight (~88 GiB free, 91% used). A local Time Machine snapshot (`com.apple.TimeMachine.2026-10-17-175426.local`) was holding ~88 GB; user was running a backup first. `tmutil deletelocalsnapshots 2026-10-17-175426` frees it (ask the user first).

## Installed in the VM (all verified working)
- Git 2.56 (ARM64), Python 3.12.8 at `C:\Program Files\Python312-arm64` (note the `-arm64`), VS 2022 Build Tools (MSVC 14.44, Windows 11 SDK).
- KDE Craft at `C:\CraftRoot`, ABI `windows-cl-msvc2022-x86_64` (x64 under emulation). Use it via `. C:\CraftRoot\craft\craftenv.ps1`, then `craft ...`.
- From Craft's binary cache: Qt 6.12.0 (qtbase, qtdeclarative, qtsvg, qtmultimedia, qtspeech, qttools, qtwebengine, qtwebchannel, qtpositioning, qtimageformats), taglib, gstreamer (CORE ONLY), libfftw, KF6 6.31.0 tier1-3, kstatusnotifieritem, threadweaver.
- `KGlobalAccel` built from source (tag v6.31.0, `-DKF_IGNORE_PLATFORM_CHECK=ON -DWITH_X11=OFF`) into `C:\CraftRoot`, because Craft ignores it on Windows. Source `C:\src\kglobalaccel`.
- Amarok source copy at `C:\src\amarok` (robocopy of the worktree, `/MIR /XD .git`), build dir `C:\build\amarok`.

## Configure command (script `~/amarok-winshare/configure.ps1`)
`cmake -S C:\src\amarok -B C:\build\amarok -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=C:\CraftRoot -DCMAKE_PREFIX_PATH=C:\CraftRoot -DWITH_IPOD=OFF -DWITH_LASTFM=OFF -DWITH_EMBEDDED_DB=OFF -DBUILD_TESTING=OFF -DKF_IGNORE_PLATFORM_CHECK=ON` inside the craft env. It now finds Qt6 and all KF6 components; **the first remaining failure is `gstreamer-audio-1.0` not found**.

## STATUS UPDATE (later session): configure PASSES, first compile running
- GStreamer installed by the user at `C:\Program Files\gstreamer\1.0\msvc_x86_64`; `configure.ps1` puts its `lib\pkgconfig` on `PKG_CONFIG_PATH` and `bin` on `PATH`.
- `KF6DNSSD` installed with `craft kde/frameworks/tier2/kdnssd`.
- **MariaDB 10.11.13 with embedded server built from source for Windows** (script `~/amarok-winshare/mariadb.ps1`, resume script `mariadb-resume.ps1`): source `C:\src\mariadb`, build `C:\build\mariadb`, installed into `C:\CraftRoot` (`lib\libmysqld.dll/.lib`, `lib\libmariadb.dll/.lib`, `include\mysql\mysql.h`, `bin\mariadbd.exe`). Needed two patches, saved in the Windows worktree under `scripts/windows/patches/mariadb/`: `0001-client-argv-terminator.patch` (same as macOS) and `0002-windows-embedded-hEventShutdown.patch` (upstream bug: `sql/mysqld.cc` skips defining `hEventShutdown` for `EMBEDDED_LIBRARY` on Windows but a later function uses it -> LNK2001 when linking `libmysqld.dll`). Craft's own `mysql` blueprint only offers MariaDB 10.2.12, so it was not used. Bison/flex came from `craft dev-utils/flexbison`.
- Amarok configure now passes with `-DWITH_EMBEDDED_DB=ON -DMYSQL_INCLUDE_DIR=C:/CraftRoot/include/mysql -DMYSQL_LIBRARIES=C:/CraftRoot/lib/libmariadb.lib -DMARIADBD_LIBRARIES=C:/CraftRoot/lib/libmysqld.lib` (see `configure.ps1`).
- **First compile started**: `~/amarok-winshare/build.ps1` (`cmake --build C:\build\amarok -j6 -- -k 0`), log `~/amarok-winshare/build.log`, summary with `~/amarok-winshare/progress.sh build.log`. 920 steps. Expect Qt6/Windows porting errors to fix in `~/amarok-windows` (edit there, re-run `configure.ps1` first so robocopy re-syncs the source into `C:\src\amarok`, then `build.ps1`).
- Still to do after it builds: run the app in the VM (GStreamer `bin` and `C:\CraftRoot\bin`/`lib` on PATH, Qt plugin path), then write `scripts/windows/` setup script, commit on `windows-port` (no Claude trailer), push to the fork.

## Next steps
1. **Install GStreamer** (Craft's `libs/gstreamer` is core only; there is no gst-plugins-base blueprint). Installer already downloaded and SHA-256 verified: `C:\dl\gst.exe` (official 1.28.8 MSVC x64 from gstreamer.freedesktop.org). Not installed yet: the install attempt was blocked by the permission classifier then interrupted. Run in an Administrator PowerShell in the VM (or ask the user to add a Bash permission rule): `C:\dl\gst.exe /quiet /norestart ADDLOCAL=ALL INSTALLDIR=C:\gstreamer`. Then find `gstreamer-audio-1.0.pc` under `C:\gstreamer` and set `PKG_CONFIG_PATH` to its folder (and put its `bin` on PATH) before re-running configure.
2. Re-run configure and fix the next missing deps. Expect more: mysql/embedded DB (Craft has `binary/_win/mysql`; embedded server support unconfirmed, `WITH_EMBEDDED_DB=OFF` for now), libmtp/libusb (optional, see below), libgcrypt, others.
3. First compile (`cmake --build C:\build\amarok`), then fix Qt6/Windows porting errors in `~/amarok-windows` (edit on the Mac, re-sync with robocopy). Windows-specific code is in files using `Q_OS_WIN`/`WIN32`: `src/App.cpp`, `src/main.cpp`, `src/core/support/Debug.*`, `src/core/support/Amarok.cpp`, `src/dbus/mpris2/Mpris2.cpp`, `src/dialogs/CollectionSetup.cpp`, `src/widgets/Osd.cpp`, `src/core-impl/collections/db/MountPointManager.cpp`, mysql storage CMake files.
4. Run the app in the VM; write a `scripts/windows/` setup script mirroring `scripts/macos/setup-and-build.sh`; commit on `windows-port` and push to the fork.

## Gotchas learned
- **Do not pass `--no-cache` to craft**: it ignores KDE's binary cache and compiles everything from source (hours). Use binary packages.
- **No `amarok` blueprint exists** in craft-blueprints-kde (`craft amarok` says "Failed to find"; its "similar package" is cmark). Install deps by blueprint path instead, e.g. `craft libs/qt6/qtbase kde/frameworks/tier3 ...`; frameworks live at `kde/frameworks/tierN/<name>`.
- `libs/libusb` has no binary and fails to compile (warning-as-error); it was dropped along with `libs/libcurl` (queued behind it). Only needed for the optional MTP collection.
- Craft allows one instance at a time (a stale `craft --search` can hold the lock).
- `prlctl exec` mangles quoting: put PowerShell in `.ps1` files on the share and run with `-File`.
- Running downloaded installers/scripts (Craft bootstrap, the GStreamer installer) was blocked twice by the permission classifier; the user ran the Craft bootstrap by hand. Expect to hand such steps to the user.
- PowerShell on the VM blocks scripts by default: use `-ExecutionPolicy Bypass`.
- Checking out `master` in `~/amarok` swaps the macOS work out from under the running build: use the `~/amarok-windows` worktree for Windows work, never switch branches in `~/amarok`.

## STATUS UPDATE 3: WINDOWS BUILD RUNS (UI up, icons working)
- Full compile + link OK on `windows-port` (commits: MSVC fixes, MariaDB patches, breeze icon theme + `WITH_DOC` option; all local, NOT pushed). Installed into `C:\CraftRoot` with `cmake --install C:\build\amarok` (`configure.ps1` now passes `-DWITH_DOC=OFF`; the handbook breaks on the space in `C:\Program Files`).
- `~/amarok-winshare/rebuild-install.ps1` = robocopy source -> build -> install. `run`/screenshot helpers: `shot.ps1` (launch from a clean env + screenshot to `guest-shot.png`; `prlctl capture` often returns black), `plain2.ps1` (`--version` from a clean env).
- Runtime fixes needed so a double-click of `C:\CraftRoot\bin\amarok.exe` works (all done in the VM, none are in git):
  1. `libmysqld.dll` and `libmariadb.dll` copied from `C:\CraftRoot\lib` to `C:\CraftRoot\bin` (error 0xC0000135 otherwise).
  2. User env: `PATH` += `C:\Program Files\gstreamer\1.0\msvc_x86_64\bin` (missing `gstaudio-1.0-0.dll` otherwise).
  3. GStreamer plugin scan crashed with "gst-plugin-scanner: entry point cairo_ft_font_options_substitute not found in pangocairo-1.0-0.dll": Craft's older cairo/glib DLLs in `C:\CraftRoot\bin` shadow GStreamer's own. Workaround: curated plugin folder `C:\AmarokGst` (35 audio/tag plugins copied from the official install, script `gstcurate.ps1`) with user env `GST_PLUGIN_SYSTEM_PATH` and `GST_PLUGIN_PATH` = `C:\AmarokGst`. Proper fix later: bundle ONE consistent GStreamer (official) with the app instead of mixing with Craft's core/glib/cairo.
- Icons: `App::App()` (Q_OS_WINDOWS) sets theme `breeze` and adds `QStandardPaths::GenericDataLocation`/`icons` and `/amarok/icons` to the icon search paths (same cause as macOS).
- Not yet tested on Windows: actual audio playback (WASAPI), adding a music folder / collection scan with the embedded MariaDB, tray icon, notifications. The Mac equivalents are also untested.
- TODO: push `windows-port` and the new `macos-qt6-port` commit to the fork (ask user), write `scripts/windows/` setup script (GStreamer install + curated plugin dir + DLL copy), consider moving the shared icon-theme code to a common place.

## STATUS UPDATE 4: FRESH-INSTALL TEST OF THE WINDOWS BUILD PASSED
A brand-new Parallels VM ("Windows 11 Fresh", Windows 11 ARM64, created from the ISO; note: `prlctl create` gives TPM type `tis`, Windows on ARM needs `crb` = `<Type>201</Type>` in `config.pvs`, which has to be edited by hand while the VM is stopped) was set up ONLY with `scripts/windows/setup-and-build.ps1` on branch `windows-port`, stage by stage, and ended with a running Amarok that loads and plays a file.
- Stages: prereqs (~4 min), craft, deps (~8 min, Craft binary cache), gstreamer (~1.5 min), mariadb (~16 min), amarok (~25 min, 908 steps), post, test. Total roughly 1 hour unattended. Run in an elevated shell; with `prlctl exec` use SYSTEM (no `--current-user`) for `prereqs` and `gstreamer`, the current user for the rest.
- GStreamer now installs to `C:\CraftRoot\gstreamer\1.0\msvc_x86_64` (own folder: merging into `C:\CraftRoot\bin` would overwrite Craft's glib/cairo). The post stage sets, for the user: `PATH` += its `bin`, `GSTREAMER_1_0_ROOT_MSVC_X86_64`, `GST_PLUGIN_PATH`/`GST_PLUGIN_SYSTEM_PATH` = `C:\AmarokGst` (curated audio-only plugins).
- Script bugs the clean run found and fixed (all committed on `windows-port`): native stderr text aborting stages under `$ErrorActionPreference='Stop'` (PS 5.1); the Inno Setup GStreamer installer needs `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=<full path>` (MSI-style flags make it wait forever in an invisible window); `Resolve-Path().Path` carries a provider prefix on UNC paths (use `.ProviderPath`) and robocopy failures were hidden; `C:\` root is not writable for a normal user (use `$env:TEMP`).
- Gotchas for driving the VM from the Mac: background jobs started with `( ... &)` can silently die, run long stages as a tracked background Bash task instead; progress bars swallow the end of logs, check marker files `C:\amarok-build\.done\<stage>` or the real output (e.g. DLLs on disk) instead of trusting a log tail; `prlctl capture` often returns black, take screenshots from inside the guest with `.NET CopyFromScreen` (`~/amarok-winshare/snap.ps1`).
- Verified at the end: `amarok.exe --version` from a clean environment, the full UI with icons, and playback of a generated 30 s WAV (title bar shows the track, position advances). Not verified: audible sound, scanning a music folder into the embedded DB, tray icon, notifications.
- Open: push `windows-port` and `macos-qt6-port` to the fork (ask the user first), then the same kind of fresh-install test for macOS (`scripts/macos/setup-and-build.sh` has never been run end to end).

## STATUS UPDATE 5: FRESH-INSTALL TEST OF THE macOS BUILD PASSED
A brand-new Parallels macOS VM ("macOS Fresh", macOS 27.0.1 build 26A434 from Apple's restore image `UniversalMac_27.0.1_26A434_Restore.ipsw`, 6 CPUs, 8 GB RAM, admin user `amarok`) was set up ONLY with `scripts/macos/setup-and-build.sh` on `macos-qt6-port` and ended with Amarok running (full UI, sidebar icons, first-run "Select collection folder" dialog).
- Stages (all on a clean machine): `prereqs` (new: Xcode CLT + Homebrew; needs the user's admin password, run by hand in Terminal), `deps` (~188 Homebrew formulae incl. Qt 6.12), `kf6` (39 frameworks from source, passed first time), `mariadb` (10.11 embedded, argv patch applied automatically), `amarok` (1283 steps), then launch.
- Bug the clean install found and fixed (commit on `macos-qt6-port`, not pushed): the analyzer applet linked `FFTW3_LIBRARIES` but never added `FFTW3_INCLUDE_DIRS`, so `fftw3.h` was not found with Homebrew (it only worked on the dev Mac by luck). Fix: `target_include_directories(amarok_context_applet_analyzer PRIVATE ${FFTW3_INCLUDE_DIRS})` in `src/context/applets/analyzer/CMakeLists.txt`. The same one-liner is worth adding to `windows-port` (that build did not need it).
- How the VM was driven from the Mac (Parallels macOS guests): shared folders do NOT mount; instead the repo was served over HTTP on the Parallels private network (`python3 -m http.server --bind 10.211.55.2`, a `git clone --depth 1` tarball) and fetched with `curl` inside the guest. `prlctl exec` runs as root and mangles nested quoting: pass simple direct arguments (`prlctl exec VM /usr/bin/sudo -u amarok /bin/bash /tmp/script.sh`) instead of `bash -c '...'`; paths with spaces must be avoided. Run stages through a tiny `stage.sh` that logs to `~/stage-<name>.log` in the guest. Never wrap a long stage in `timeout` (a 60 s timeout killed `brew install` once). Launch the GUI into the user's desktop session with `launchctl asuser 501 sudo -u amarok ...`. `prlctl capture` works on the macOS VM (it returns black on Windows).
- Not verified on macOS: audio playback, scanning a music folder into the embedded DB, tray/dock menu, notifications (the Mac port has the Qt6 fixes for these but no runtime test yet).
- Open: push `macos-qt6-port` (FFTW fix, prereqs stage, notes) and add the FFTW fix to `windows-port`.

## STATUS UPDATE 6: UPSTREAM MERGED, CI WORKFLOWS DISPATCHED (2026-11-15)
- **Upstream** (`origin` = `https://github.com/kde/amarok`, remote `fork` = `NitrosGits/amarok`): fetched 5 new commits (4 translation syncs plus `e48e89acda`, a file browser duplicate-entries fix in `src/browsers/filebrowser/FileView.cpp`). Merged `origin/master` into BOTH `macos-qt6-port` (`0df9c890f7`) and `windows-port` (`92edca84f6`) with no conflicts, no Claude trailer. (Superseded: see STATUS UPDATE 7, `master` on the fork now has both ports.) Not rebuilt locally against the merge; CI below is the test.
- **Pushed** both branches to the fork (plain fast-forward, no force).
- **Workflows** (`.github/workflows/macos.yml` on `macos-qt6-port`, `windows.yml` on `windows-port`) trigger only on `workflow_dispatch` or `v*` tags, so a push alone runs nothing. The fork is public (free Actions minutes) and its default branch `master` already contains both files, which is what lets `gh` dispatch them. Run: `gh workflow run macos.yml -R NitrosGits/amarok --ref macos-qt6-port` and `gh workflow run windows.yml -R NitrosGits/amarok --ref windows-port`; watch with `gh run list -R NitrosGits/amarok` / `gh run view <id> --log-failed`.
- **First macOS dispatch was cancelled in 3 s** with the annotation `The configuration 'macos-14-arm64-us-default' is not supported`: the `macos-14` runner image was retired after the last successful run (2 Nov). Fix committed on `macos-qt6-port` (`7713dcc10b`, pushed): `runs-on: macos-15`. The workflow already selects the newest installed Xcode. Re-dispatched; result not yet known when this was written. The cached KF6/MariaDB prefix was built on `macos-14`, so a cache miss or a rebuild of the prefix is possible on `macos-15`.
- Open: check both dispatched runs and fix whatever the merged code or the new runner breaks; add the FFTW include fix to `windows-port` (see Update 5); (Done in Update 7: `master` is merged and fast-forwarded.)

## STATUS UPDATE 7: `master` HAS BOTH PORTS (2026-11-16)
- **`master` on the fork (`NitrosGits/amarok`) now contains both the macOS and the Windows port.** `fork/master` = `67635e1fae`, two merge commits on top of the previous `99ce69ad1f`: `ac0cfaa7d8` (`macos-qt6-port`) and `67635e1fae` (`windows-port`). Plain fast-forward push, no force, no Claude trailer. Local `master` is level with it. This is the branch to build from and to base new work on.
- **Tested first, as a combined tree.** A throwaway branch `combined-test` (the same two merges onto the old `master`) was built by CI on both platforms: macOS `macos-15` success (1h 10m), Windows success (57m). Both single-branch runs passed too (macOS 1h 7m, Windows 1h 23m). The merge commits were then redone with proper messages and the tree was diffed against `combined-test` before pushing: identical. `combined-test` has been deleted.
- **What that does and does not cover:** CI proves the combined tree compiles, installs and packages on both platforms. It does not exercise the app: playback, scanning a music folder into the embedded DB, the tray/dock menu and notifications are still untested on both.
- **Where things live now:**
  - `scripts/macos/setup-and-build.sh` and `scripts/windows/setup-and-build.ps1` (+ NSIS installer scripts under `scripts/windows/`), patches in `scripts/macos/patches/mariadb/` and `scripts/windows/patches/mariadb/`.
  - Workflows: `.github/workflows/macos.yml` (runs on `macos-15`; `macos-14` was retired) and `windows.yml`. Both trigger only on `workflow_dispatch` or `v*` tags: `gh workflow run macos.yml -R NitrosGits/amarok --ref master` (same for `windows.yml`).
  - This file (`HAND.md`) is on `master`. The feature branches `macos-qt6-port` and `windows-port` still exist on the fork with their own, older copies; treat `master` as the source of truth and update this file there.
- **Not done / open:** nothing has gone to KDE's `origin` (upstream `https://github.com/kde/amarok`); no PR. Upstream was last merged on 2026-11-15 (5 commits); re-check with `git fetch origin` and `git rev-list --left-right --count origin/master...master`. Add the FFTW include fix (`src/context/applets/analyzer/CMakeLists.txt`, see Update 5) to the Windows side if it is ever needed there. Runtime testing listed above.
