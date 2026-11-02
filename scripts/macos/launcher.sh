#!/bin/bash
# Bundle executable: Amarok needs a D-Bus session bus, which macOS does not provide to GUI apps,
# so run a private one (shared by all Amarok instances of this user), then start the real binary.
here="$(cd "$(dirname "$0")" && pwd)"
res="$here/../Resources"

dir="${TMPDIR:-/tmp}/amarok-dbus"
mkdir -p "$dir"
chmod 700 "$dir"
sock="$dir/bus"
if ! /usr/bin/nc -zU "$sock" >/dev/null 2>&1; then
  rm -f "$sock"
  cat > "$dir/session.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <keep_umask/>
  <listen>unix:path=$sock</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
  "$here/dbus-daemon" --config-file="$dir/session.conf" --fork
fi

export DBUS_SESSION_BUS_ADDRESS="unix:path=$sock"
# KIO workers are separate processes in Frameworks/libexec and have no qt.conf of their own
export QT_PLUGIN_PATH="$here/../PlugIns"
export XDG_DATA_DIRS="$res"
export QML_IMPORT_PATH="$res/qml" QML2_IMPORT_PATH="$res/qml"
export GST_PLUGIN_SYSTEM_PATH="$here/../PlugIns/gstreamer" GST_PLUGIN_PATH="$here/../PlugIns/gstreamer"
export GST_PLUGIN_SCANNER="$here/gst-plugin-scanner"
mkdir -p "$HOME/Library/Caches/Amarok"
export GST_REGISTRY="$HOME/Library/Caches/Amarok/gstreamer-registry.bin"
exec "$here/amarok-bin" "$@"
