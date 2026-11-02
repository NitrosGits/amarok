; Tiny launcher (becomes Amarok.exe next to the app tree): points the process at the bundled GStreamer and
; starts app\bin\amarok.exe. Built by package.ps1 with /DOUT=<exe path>.
Unicode true
OutFile "${OUT}"
RequestExecutionLevel user
SilentInstall silent
Icon "${ICON}"

Section
  System::Call 'kernel32::SetEnvironmentVariable(t "GST_PLUGIN_SYSTEM_PATH", t "$EXEDIR\gstreamer\plugins")'
  System::Call 'kernel32::SetEnvironmentVariable(t "GST_PLUGIN_PATH", t "$EXEDIR\gstreamer\plugins")'
  System::Call 'kernel32::SetEnvironmentVariable(t "GST_PLUGIN_SCANNER", t "$EXEDIR\gstreamer\bin\gst-plugin-scanner.exe")'
  System::Call 'kernel32::SetEnvironmentVariable(t "QT_PLUGIN_PATH", t "$EXEDIR\plugins")'   ; also reaches KIO workers
  ReadEnvStr $0 PATH
  System::Call 'kernel32::SetEnvironmentVariable(t "PATH", t "$EXEDIR\bin;$EXEDIR\gstreamer\bin;$0")'
  SetOutPath "$EXEDIR\bin"
  Exec '"$EXEDIR\bin\amarok.exe"'
SectionEnd
