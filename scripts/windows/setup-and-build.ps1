<#
.SYNOPSIS
  Build and install Amarok on Windows (x64 MSVC, KDE Craft), from a clean machine.

.DESCRIPTION
  Run in an ELEVATED Windows PowerShell inside the repository checkout:
      powershell -ExecutionPolicy Bypass -File scripts\windows\setup-and-build.ps1 [-Stage all]

  Stages (each is idempotent and leaves a marker in $Work\.done, so a failed run can be resumed):
      prereqs    Git, Python 3, Visual Studio 2022 Build Tools (C++ workload + Windows SDK)
      craft      Bootstrap KDE Craft into $Craft
      deps       Qt6, KDE Frameworks, TagLib, FFTW from Craft's binary cache; KGlobalAccel from source
      gstreamer  Official GStreamer MSVC runtime+devel installer (checksum verified)
      mariadb    MariaDB 10.11 with the embedded server, built from source with the patches in scripts\windows\patches
      amarok     Configure, build and install Amarok into $Craft
      post       DLL copies, curated GStreamer plugin folder, user environment variables
      test       Smoke test: amarok --version from a clean environment
      all        everything above, in order

  Notes: Craft has no "amarok" blueprint, so dependencies are installed individually. Craft only builds
  x64 on Windows; on an ARM64 host this runs under emulation (slow but works).
#>
param(
    [ValidateSet('all','prereqs','craft','deps','gstreamer','mariadb','amarok','post','test')]
    [string]$Stage = 'all',
    [string]$Craft = 'C:\CraftRoot',
    [string]$Work  = 'C:\amarok-build',
    [string]$Gst   = '',   # default: $Craft\gstreamer\1.0\msvc_x86_64
    [string]$GstVersion = '1.28.8',
    [string]$MariaDbTag = 'mariadb-10.11.13',
    [string]$KfTag = 'v6.31.0',
    [int]$Jobs = [Environment]::ProcessorCount
)

# Windows PowerShell 5.1 turns a native program's stderr text (git progress, Craft's banner) into a
# terminating error under 'Stop' once output is redirected, so check exit codes explicitly instead.
$ErrorActionPreference = 'Continue'
if (-not $Gst) { $Gst = Join-Path $Craft 'gstreamer\1.0\msvc_x86_64' }
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo    = [IO.Path]::GetFullPath((Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath).TrimEnd('\')   # .Path carries a provider prefix on UNC paths
$Patches = Join-Path $PSScriptRoot 'patches\mariadb'
$Done    = Join-Path $Work '.done'
$Dl      = Join-Path $Work 'download'
$Src     = Join-Path $Work 'src'
New-Item -ItemType Directory -Force $Work, $Done, $Dl, $Src | Out-Null

function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -f HH:mm:ss), $m) -ForegroundColor Cyan }
function IsDone($n) { Test-Path (Join-Path $Done $n) }
function MarkDone($n) { New-Item -ItemType File -Force (Join-Path $Done $n) | Out-Null }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Run a command inside the Craft environment (compiler, cmake, ninja, ...), in a child PowerShell.
function InCraft([string]$Script) {
    $f = Join-Path $Work ("incraft-{0}.ps1" -f [guid]::NewGuid().ToString('N').Substring(0,8))
    $body = ". '$Craft\craft\craftenv.ps1'`n`$ErrorActionPreference='Continue'`n$Script`nexit `$LASTEXITCODE"
    Set-Content -Path $f -Value $body -Encoding UTF8
    powershell -NoProfile -ExecutionPolicy Bypass -File $f
    $rc = $LASTEXITCODE
    Remove-Item $f -ErrorAction SilentlyContinue
    if ($rc -ne 0) { Fail "command failed in Craft environment (exit $rc): $($Script.Split("`n")[0])" }
}

function Download($url, $out) {
    if (Test-Path $out) { return }
    Log "downloading $url"
    # invent.kde.org answers 403 to PowerShell's default user agent from some networks (GitHub's runners)
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
    try { Invoke-WebRequest $url -OutFile $out -UserAgent $ua -ErrorAction Stop }
    catch {
        $mirror = $url -replace '^https://invent\.kde\.org/packaging/craft/-/raw/master/', 'https://raw.githubusercontent.com/KDE/craft/master/'
        if ($mirror -eq $url) { throw }
        Log "failed ($($_.Exception.Message)); trying $mirror"
        Invoke-WebRequest $mirror -OutFile $out -UserAgent $ua -ErrorAction Stop
    }
}

# ---------------------------------------------------------------------------------------------
function Stage-Prereqs {
    if (IsDone 'prereqs') { Log 'prereqs: done'; return }
    if (-not (Test-Admin)) { Fail 'prereqs needs an elevated PowerShell' }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $rel = Invoke-RestMethod https://api.github.com/repos/git-for-windows/git/releases/latest -Headers @{ 'User-Agent' = 'amarok-setup' } -ErrorAction Stop
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { '64-bit' }
        $a = $rel.assets | Where-Object { $_.name -match "$arch\.exe$" -and $_.name -notmatch 'Portable|busybox|MinGit' } | Select-Object -First 1
        Download $a.browser_download_url (Join-Path $Dl 'git.exe')
        Start-Process (Join-Path $Dl 'git.exe') -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES' -Wait
    }
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        $pa = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
        Download "https://www.python.org/ftp/python/3.12.8/python-3.12.8-$pa.exe" (Join-Path $Dl 'python.exe')
        Start-Process (Join-Path $Dl 'python.exe') -ArgumentList '/quiet','InstallAllUsers=1','PrependPath=1','Include_test=0' -Wait
    }
    $vsw = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $haveVs = (Test-Path $vsw) -and (& $vsw -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if (-not $haveVs) {
        Download 'https://aka.ms/vs/17/release/vs_BuildTools.exe' (Join-Path $Dl 'vs_BuildTools.exe')
        Log 'installing Visual Studio Build Tools (about 8 GB, takes a while)'
        $p = Start-Process (Join-Path $Dl 'vs_BuildTools.exe') -Wait -PassThru -ArgumentList '--quiet','--wait','--norestart','--nocache',
            '--add','Microsoft.VisualStudio.Workload.VCTools','--includeRecommended',
            '--add','Microsoft.VisualStudio.Component.VC.Tools.ARM64','--add','Microsoft.VisualStudio.Component.Windows11SDK.26100'
        if ($p.ExitCode -notin 0,3010) { Fail "Visual Studio Build Tools install failed (exit $($p.ExitCode))" }
    }
    # new PATH for this session
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    foreach ($t in 'git','python') { if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Fail "$t not on PATH after install; open a new PowerShell and re-run" } }
    MarkDone 'prereqs'
}

# ---------------------------------------------------------------------------------------------
function Stage-Craft {
    if (IsDone 'craft') { Log 'craft: done'; return }
    if (Test-Path "$Craft\craft\craftenv.ps1") { MarkDone 'craft'; return }
    New-Item -ItemType Directory -Force $Craft, "$Craft\download" | Out-Null
    $py = (Get-Command python).Source
    $boot = "$Craft\download\CraftBootstrap.py"
    Download 'https://invent.kde.org/packaging/craft/-/raw/master/setup/CraftBootstrap.py' $boot
    if (-not (Test-Path $boot)) { Fail 'could not download CraftBootstrap.py' }
    Log 'bootstrapping Craft'
    & $py $boot --prefix $Craft --branch master --use-defaults
    if ($LASTEXITCODE -ne 0) { Fail 'Craft bootstrap failed' }
    if (-not (Test-Path "$Craft\craft\craftenv.ps1")) { Fail 'Craft bootstrap did not produce craftenv.ps1' }
    MarkDone 'craft'
}

# ---------------------------------------------------------------------------------------------
function Stage-Deps {
    if (IsDone 'deps') { Log 'deps: done'; return }
    # NOTE: never use "craft --no-cache": it compiles everything from source (hours).
    # libusb/libcurl are skipped: no binary package and libusb fails to compile; only the optional MTP device collection needs them.
    Log 'installing Qt6, KDE Frameworks, TagLib, FFTW from Craft binary cache'
    InCraft @'
craft libs/qt6/qtbase libs/qt6/qtdeclarative libs/qt6/qtsvg libs/qt6/qtmultimedia libs/qt6/qtspeech libs/qt6/qttools libs/qt6/qtwebengine libs/qt6/qtwebchannel libs/qt6/qtpositioning libs/qt6/qtimageformats libs/taglib libs/libfftw kde/frameworks/tier3 kde/frameworks/tier2/kstatusnotifieritem kde/frameworks/tier1/threadweaver kde/frameworks/tier2/kdnssd
'@
    # Craft ignores kglobalaccel on Windows; build the client library from source.
    if (-not (Test-Path "$Craft\lib\cmake\KF6GlobalAccel\KF6GlobalAccelConfig.cmake")) {
        $kga = Join-Path $Src 'kglobalaccel'
        if (-not (Test-Path $kga)) { git clone --depth 1 --branch $KfTag https://invent.kde.org/frameworks/kglobalaccel.git $kga; if ($LASTEXITCODE) { Fail 'git clone kglobalaccel' } }
        InCraft @"
cmake -S '$kga' -B '$Work\build\kglobalaccel' -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX='$Craft' -DCMAKE_PREFIX_PATH='$Craft' -DBUILD_TESTING=OFF -DBUILD_QCH=OFF -DKF_IGNORE_PLATFORM_CHECK=ON -DWITH_X11=OFF
if (`$LASTEXITCODE -ne 0) { exit 1 }
cmake --build '$Work\build\kglobalaccel'
if (`$LASTEXITCODE -ne 0) { exit 1 }
cmake --install '$Work\build\kglobalaccel'
"@
    }
    MarkDone 'deps'
}

# ---------------------------------------------------------------------------------------------
function Stage-Gstreamer {
    if (IsDone 'gstreamer') { Log 'gstreamer: done'; return }
    if (-not (Test-Admin)) { Fail 'gstreamer needs an elevated PowerShell' }
    if (-not (Test-Path "$Gst\lib\pkgconfig\gstreamer-audio-1.0.pc")) {
        # Craft's libs/gstreamer is the core only (no gst-plugins-base), so use the official installer.
        $base = "https://gstreamer.freedesktop.org/data/pkg/windows/$GstVersion/msvc/gstreamer-1.0-msvc-x86_64-$GstVersion.exe"
        $exe = Join-Path $Dl 'gstreamer.exe'
        Download "$base.sha256sum" (Join-Path $Dl 'gstreamer.sha')
        Download $base $exe
        $want = (Get-Content (Join-Path $Dl 'gstreamer.sha')).Split(' ')[0].ToLower()
        $got = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
        if ($want -ne $got) { Remove-Item $exe; Fail "GStreamer installer checksum mismatch (expected $want, got $got)" }
        Log 'installing GStreamer'
        # The official installer is Inno Setup: MSI-style switches are ignored and it would wait for a click
        # in an invisible window. Use Inno's silent switches and keep a log.
        $p = Start-Process $exe -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=$Gst","/LOG=$Work\gstreamer-install.log" -Wait -PassThru
        if ($p.ExitCode -notin 0,3010) { Fail "GStreamer installer failed (exit $($p.ExitCode)); see $Work\gstreamer-install.log" }
    }
    if (-not (Test-Path "$Gst\lib\pkgconfig\gstreamer-audio-1.0.pc")) { Fail "GStreamer not found at $Gst (use -Gst to point at it)" }
    MarkDone 'gstreamer'
}

# ---------------------------------------------------------------------------------------------
function Stage-Mariadb {
    if (IsDone 'mariadb') { Log 'mariadb: done'; return }
    if (Test-Path "$Craft\lib\libmysqld.lib") { MarkDone 'mariadb'; return }
    InCraft 'craft dev-utils/flexbison'
    $db = Join-Path $Src 'mariadb'
    if (-not (Test-Path $db)) { git clone --depth 1 --branch $MariaDbTag https://github.com/MariaDB/server.git $db; if ($LASTEXITCODE) { Fail 'git clone mariadb' } }
    git -C $db submodule update --init --depth 1
    if ($LASTEXITCODE) { Fail 'git submodule update (mariadb)' }
    foreach ($pf in Get-ChildItem $Patches -Filter *.patch | Sort-Object Name) {
        git -C $db apply --check -R $pf.FullName 2>$null
        if ($LASTEXITCODE -eq 0) { Log "mariadb patch already applied: $($pf.Name)"; continue }
        git -C $db apply $pf.FullName
        if ($LASTEXITCODE) { Fail "mariadb patch failed: $($pf.Name)" }
        Log "applied mariadb patch: $($pf.Name)"
    }
    InCraft @"
`$b = Get-ChildItem '$Craft\dev-utils' -Recurse -Filter 'bison.exe' | Select-Object -First 1
if (-not `$b) { `$b = Get-ChildItem '$Craft\dev-utils' -Recurse -Filter 'win_bison.exe' | Select-Object -First 1 }
`$env:PATH = (Split-Path `$b.FullName) + ';' + `$env:PATH
cmake -S '$db' -B '$Work\build\mariadb' -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX='$Craft' -DWITH_EMBEDDED_SERVER=ON -DWITH_UNIT_TESTS=OFF -DPLUGIN_TOKUDB=NO -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO -DPLUGIN_CONNECT=NO -DWITH_WSREP=OFF
if (`$LASTEXITCODE -ne 0) { exit 1 }
cmake --build '$Work\build\mariadb' --target install -j $Jobs
"@
    if (-not (Test-Path "$Craft\lib\libmysqld.lib")) { Fail 'MariaDB embedded library was not installed' }
    MarkDone 'mariadb'
}

# ---------------------------------------------------------------------------------------------
function Stage-Amarok {
    $srcDir = Join-Path $Work 'amarok-src'
    $bld = Join-Path $Work 'build\amarok'
    # build from a local copy: building over a network share is very slow
    robocopy $Repo $srcDir /MIR /XD .git build build-macos /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8 -or -not (Test-Path (Join-Path $srcDir 'CMakeLists.txt'))) { Fail "copying the source from $Repo to $srcDir failed (robocopy exit $LASTEXITCODE)" }
    $g = $Gst
    InCraft @"
`$env:PKG_CONFIG_PATH = '$g\lib\pkgconfig;' + `$env:PKG_CONFIG_PATH
`$env:PATH = '$g\bin;$Craft\lib;' + `$env:PATH
`$env:LIB = '$g\lib;' + `$env:LIB
cmake -S '$srcDir' -B '$bld' -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX='$Craft' -DCMAKE_PREFIX_PATH='$Craft' -DWITH_IPOD=OFF -DWITH_LASTFM=OFF -DWITH_DOC=OFF -DBUILD_TESTING=OFF -DKF_IGNORE_PLATFORM_CHECK=ON -DWITH_EMBEDDED_DB=ON -DMYSQL_INCLUDE_DIR='$($Craft.Replace('\','/'))/include/mysql' -DMYSQL_LIBRARIES='$($Craft.Replace('\','/'))/lib/libmariadb.lib' -DMARIADBD_LIBRARIES='$($Craft.Replace('\','/'))/lib/libmysqld.lib'
if (`$LASTEXITCODE -ne 0) { exit 1 }
cmake --build '$bld' -j $Jobs
if (`$LASTEXITCODE -ne 0) { exit 1 }
cmake --install '$bld'
"@
    if (-not (Test-Path "$Craft\bin\amarok.exe")) { Fail 'amarok.exe was not installed' }
}

# ---------------------------------------------------------------------------------------------
function Stage-Post {
    # MariaDB installs its DLLs into lib\, but Windows only looks next to the exe (and on PATH).
    Copy-Item "$Craft\lib\libmysqld.dll","$Craft\lib\libmariadb.dll" "$Craft\bin\" -Force

    # Craft's gstreamer/glib/cairo DLLs in $Craft\bin shadow the official GStreamer's own ones, so the plugin
    # scanner fails on plugins Amarok does not use (e.g. pangocairo). Give GStreamer a curated audio-only set.
    $curated = 'C:\AmarokGst'
    New-Item -ItemType Directory -Force $curated | Out-Null
    $want = 'gstcoreelements','gstplayback','gstaudioconvert','gstaudioresample','gstaudiotestsrc','gstvolume','gstequalizer','gstautodetect','gstwasapi','gstwasapi2','gsttypefindfunctions','gstaudioparsers','gstid3demux','gstapetag','gsticydemux','gstisomp4','gstmpg123','gstlame','gstvorbis','gstogg','gstopus','gstflac','gstwavparse','gstwavenc','gstaiff','gstlibav','gstasf','gstmatroska','gstaudiofx','gstspectrum','gstlevel','gstdirectsound','gstreplaygain','gsttaglib','gstrtp'
    foreach ($w in $want) { Copy-Item "$Gst\lib\gstreamer-1.0\$w.dll" $curated -Force -ErrorAction SilentlyContinue }

    # Per-user environment so that double-clicking amarok.exe works.
    $u = [Environment]::GetEnvironmentVariable('Path','User'); if (-not $u) { $u = '' }
    if ($u -notlike "*$Gst\bin*") { [Environment]::SetEnvironmentVariable('Path', (($u.TrimEnd(';') + ";$Gst\bin").TrimStart(';')), 'User') }
    # The silent installer does not set these (the GUI one does); set them for the user.
    [Environment]::SetEnvironmentVariable('GSTREAMER_1_0_ROOT_MSVC_X86_64', $Gst, 'User')
    [Environment]::SetEnvironmentVariable('GST_PLUGIN_SYSTEM_PATH', $curated, 'User')
    [Environment]::SetEnvironmentVariable('GST_PLUGIN_PATH', $curated, 'User')
    Log 'post: done (log out and in, or start a new shell, to pick up the environment)'
}

# ---------------------------------------------------------------------------------------------
function Stage-Test {
    # Start amarok.exe the way Explorer would: machine+user PATH only, no Craft/Qt variables.
    $path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "$Craft\bin\amarok.exe"; $psi.Arguments = '--version'; $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['Path'] = $path
    foreach ($k in 'GST_PLUGIN_PATH','GST_PLUGIN_SYSTEM_PATH') { $v = [Environment]::GetEnvironmentVariable($k,'User'); if ($v) { $psi.EnvironmentVariables[$k] = $v } }
    $p = [Diagnostics.Process]::Start($psi); $p.WaitForExit(30000) | Out-Null
    $out = $p.StandardOutput.ReadToEnd().Trim()
    if ($p.ExitCode -ne 0 -or $out -notmatch '^amarok ') { Fail ("smoke test failed: exit 0x{0:X} output '{1}'" -f $p.ExitCode, $out) }
    Log "smoke test OK: $out"
}

# ---------------------------------------------------------------------------------------------
$order = 'prereqs','craft','deps','gstreamer','mariadb','amarok','post','test'
$todo = if ($Stage -eq 'all') { $order } else { @($Stage) }
foreach ($s in $todo) {
    Log "=== stage: $s ==="
    switch ($s) {
        'prereqs'   { Stage-Prereqs }
        'craft'     { Stage-Craft }
        'deps'      { Stage-Deps }
        'gstreamer' { Stage-Gstreamer }
        'mariadb'   { Stage-Mariadb }
        'amarok'    { Stage-Amarok }
        'post'      { Stage-Post }
        'test'      { Stage-Test }
    }
}
Log 'finished'
