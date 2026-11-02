; NSIS installer for Amarok (Windows x64). Built by scripts\windows\package.ps1, which passes
;   /DSTAGE=<staging dir> /DVERSION=<x.y.z> /DOUTFILE=<installer path> /DLAUNCHER=<AmarokLauncher.exe> /DICON=<amarok.ico>
Unicode true
!include "MUI2.nsh"
!include "x64.nsh"

Name "Amarok"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\Amarok"
InstallDirRegKey HKLM "Software\Amarok" "InstallDir"
RequestExecutionLevel admin
SetCompressor /SOLID lzma

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\Amarok.exe"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; 64-bit registry view (this is a 32-bit NSIS stub) and the all-users Start Menu
Function .onInit
  SetRegView 64
  SetShellVarContext all
FunctionEnd
Function un.onInit
  SetRegView 64
  SetShellVarContext all
FunctionEnd

Section "Amarok" SecMain
  SectionIn RO
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "Amarok needs 64-bit Windows."
    Abort
  ${EndIf}

  ; Microsoft Visual C++ runtime the build links against (skipped quietly when already current)
  SetOutPath "$PLUGINSDIR"
  File "${STAGE}\vc_redist.x64.exe"
  ExecWait '"$PLUGINSDIR\vc_redist.x64.exe" /install /quiet /norestart'

  SetOutPath "$INSTDIR"
  File "${LAUNCHER}"
  File /r "${STAGE}\app\*.*"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Amarok"
  CreateShortcut "$SMPROGRAMS\Amarok\Amarok.lnk" "$INSTDIR\Amarok.exe"
  CreateShortcut "$SMPROGRAMS\Amarok\Uninstall Amarok.lnk" "$INSTDIR\Uninstall.exe"

  WriteRegStr HKLM "Software\Amarok" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Amarok" "DisplayName" "Amarok"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Amarok" "DisplayIcon" "$INSTDIR\Amarok.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Amarok" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Amarok" "Publisher" "Amarok Team"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Amarok" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Amarok" "NoModify" 1
SectionEnd

Section "Uninstall"
  Delete "$SMPROGRAMS\Amarok\Amarok.lnk"
  Delete "$SMPROGRAMS\Amarok\Uninstall Amarok.lnk"
  RMDir "$SMPROGRAMS\Amarok"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Amarok"
  DeleteRegKey HKLM "Software\Amarok"
SectionEnd
