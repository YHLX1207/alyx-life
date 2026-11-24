#!/bin/sh
# DSHBox developer mode: ADB entry. Pins key location and connection, passes through the rest.
HOME=/opt/elevation/home
export HOME
ADB_VENDOR_KEYS=/opt/elevation/home/.android/keys
export ADB_VENDOR_KEYS
CONF=""
if [ -z "$ADB_SERVER_SOCKET" ]; then
    CONF="$(cat /opt/elevation/server.conf 2>/dev/null)"
fi
case "$CONF" in
    tcp:0.0.0.0:*)
        LANPORT="${CONF#tcp:0.0.0.0:}"
        /opt/elevation/real/adb -a -P "$LANPORT" start-server >/dev/null 2>&1
        ADB_SERVER_SOCKET="tcp:localhost:$LANPORT"
        export ADB_SERVER_SOCKET
        ;;
    *)
        ADB_SERVER_SOCKET="$CONF"
        [ -n "$ADB_SERVER_SOCKET" ] || ADB_SERVER_SOCKET="localfilesystem:/opt/elevation/adb.sock"
        export ADB_SERVER_SOCKET
        ;;
esac
exec /opt/elevation/real/adb "$@"
