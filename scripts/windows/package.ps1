<#
.SYNOPSIS
  Package a finished Windows build (setup-and-build.ps1) into an NSIS installer.

.DESCRIPTION
  powershell -ExecutionPolicy Bypass -File scripts\windows\package.ps1 [-Out dist-windows]

  Stages $Out\stage\app with the runtime (Craft's bin/plugins/qml/share, the official GStreamer's DLLs and the
  curated audio-only plugin set), builds a small launcher that points Amarok at that GStreamer, downloads the
  Visual C++ redistributable, and runs makensis. NSIS is installed with Chocolatey when it is missing.
#>
param(
    [string]$Craft = 'C:\CraftRoot',
    [string]$Gst   = '',
    [string]$Curated = 'C:\AmarokGst',
    [string]$Out   = '',
    [string]$Version = ''
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not $Gst) { $Gst = Join-Path $Craft 'gstreamer\1.0\msvc_x86_64' }
$Repo = [IO.Path]::GetFullPath((Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath).TrimEnd('\')
if (-not $Out) { $Out = Join-Path $Repo 'dist-windows' }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -f HH:mm:ss), $m) -ForegroundColor Cyan }

if (-not (Test-Path "$Craft\bin\amarok.exe")) { Fail "no build in ${Craft}: run setup-and-build.ps1 first" }
if (-not (Test-Path $Curated)) { Fail "$Curated is missing: run setup-and-build.ps1 -Stage post" }
if (-not $Version) { $Version = '2.8.0' }

$makensis = (Get-Command makensis -ErrorAction SilentlyContinue).Source
if (-not $makensis) { $makensis = @("${env:ProgramFiles(x86)}\NSIS\makensis.exe", "$env:ProgramFiles\NSIS\makensis.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }
if (-not $makensis) {
    Log 'installing NSIS'
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        choco install nsis -y --no-progress | Out-Null
        $makensis = "${env:ProgramFiles(x86)}\NSIS\makensis.exe"
    } else {
        # portable copy: the zip unpacks into one nsis-<version> folder
        $nz = Join-Path $env:TEMP 'nsis.zip'; $nd = Join-Path $env:TEMP 'nsis-portable'
        Invoke-WebRequest 'https://sourceforge.net/projects/nsis/files/NSIS%203/3.10/nsis-3.10.zip/download' -OutFile $nz -UserAgent 'curl/8' -ErrorAction Stop
        Remove-Item $nd -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive $nz $nd -Force
        $makensis = (Get-ChildItem $nd -Recurse -Filter makensis.exe | Select-Object -First 1).FullName
        $env:NSISDIR = Split-Path $makensis
    }
}
if (-not (Test-Path $makensis)) { Fail 'makensis not found' }

$stage = Join-Path $Out 'stage'; $app = Join-Path $stage 'app'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $app | Out-Null

Log 'staging the runtime'
foreach ($d in 'bin','plugins','qml','share','etc','resources','translations') {
    if (Test-Path "$Craft\$d") { robocopy "$Craft\$d" "$app\$d" /E /NFL /NDL /NJH /NJS /NP /XF *.lib *.pdb *.exp *.a | Out-Null }
}
# bin\ also holds Craft's build tools; keep only what Amarok runs
Get-ChildItem "$app\bin" -Filter *.exe | Where-Object { $_.Name -notmatch '^(amarok|kioworker|dbus-daemon|kbuildsycoca6|kded6|kiod6)' } | Remove-Item -Force
# Craft's Qt is configured for C:\CraftRoot; point it at the installed plugins and QML instead
Set-Content -Path (Join-Path $app 'bin\qt.conf') -Value "[Paths]`r`nPrefix = ..`r`nPlugins = plugins`r`nQml2Imports = qml`r`n" -Encoding ASCII
$gb = Join-Path $app 'gstreamer\bin'
New-Item -ItemType Directory -Force $gb, (Join-Path $app 'gstreamer\plugins') | Out-Null
Copy-Item "$Gst\bin\*.dll" $gb -Force
Copy-Item "$Gst\libexec\gstreamer-1.0\gst-plugin-scanner.exe" $gb -Force -ErrorAction SilentlyContinue
Copy-Item "$Curated\*.dll" (Join-Path $app 'gstreamer\plugins') -Force

Log 'building the launcher'
$launcher = Join-Path $stage 'Amarok.exe'
& $makensis /V1 "/DOUT=$launcher" (Join-Path $PSScriptRoot 'launcher.nsi')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $launcher)) { Fail 'launcher build failed' }

Log 'fetching the Visual C++ runtime'
Invoke-WebRequest 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile (Join-Path $stage 'vc_redist.x64.exe') -ErrorAction Stop

$installer = Join-Path $Out "Amarok-$Version-win64-setup.exe"
Log "building $installer"
& $makensis /V2 "/DSTAGE=$stage" "/DVERSION=$Version" "/DOUTFILE=$installer" "/DLAUNCHER=$launcher" (Join-Path $PSScriptRoot 'amarok.nsi')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $installer)) { Fail 'installer build failed' }
Log ("done: {0} ({1:N0} MB)" -f $installer, ((Get-Item $installer).Length / 1MB))
