#!/bin/sh
# zkindle launcher (called from KUAL).
#
# Pauses the stock Kindle UI so it doesn't draw over us, runs zkindle, then puts
# everything back. The approach mirrors KOReader's platform/kindle/koreader.sh
# (the default "framework stays up" path, FW >= 5.12 on upstart).

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/zkindle.log"
cd "$DIR" || exit 1

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# If the clock shows UTC, put a POSIX TZ string in a file named "tz" next to this
# script, e.g. for Paris:  CET-1CEST,M3.5.0,M10.5.0/3
[ -f "$DIR/tz" ] && export TZ="$(cat "$DIR/tz")"

MODE="run"
[ "$1" = "--test" ] && MODE="test"

# Give KUAL a moment to close its menu, otherwise it can pop up over us.
usleep 500000 2>/dev/null || sleep 1

if [ "$MODE" = "test" ]; then
    log "test: drawing one frame"
    ./bin/zkindle --once >>"$LOG" 2>&1
    sleep 6
    lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home
    exit 0
fi

PAUSED_AWESOME=no
STOPPED_STATUSBAR=no
PAUSED_VOLUMD=no

restore() {
    log "restoring stock UI"
    [ "$PAUSED_VOLUMD" = yes ] && killall -CONT volumd 2>/dev/null
    [ "$STOPPED_STATUSBAR" = yes ] && start statusbar 2>/dev/null
    [ "$PAUSED_AWESOME" = yes ] && killall -CONT awesome 2>/dev/null
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
    if [ -f /var/tmp/zkindle-fb.dump ]; then
        cat /var/tmp/zkindle-fb.dump >/dev/fb0
        rm -f /var/tmp/zkindle-fb.dump
    fi
    lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
    lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
}
trap restore EXIT
trap 'exit 0' TERM INT HUP

log "starting ($(cat /etc/prettyversion.txt 2>/dev/null))"

# Keep a copy of the current screen so we can restore something sane on exit.
cat /dev/fb0 >/var/tmp/zkindle-fb.dump 2>/dev/null

# Pillow = the stock status bar / overlays. Then freeze the window manager so the
# clock in the title bar stops repainting on top of us.
lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null
killall -STOP awesome 2>/dev/null && PAUSED_AWESOME=yes

# Newer firmware (PW6 / CS era) runs the status bar as its own upstart job.
if [ -f /etc/upstart/statusbar.conf ]; then
    stop statusbar 2>/dev/null && STOPPED_STATUSBAR=yes
fi

# Don't let a USB plug-in yank /mnt/us from under us while running.
if [ -e /etc/upstart/volumd.conf ] || [ -e /etc/init.d/volumd ]; then
    killall -STOP volumd 2>/dev/null && PAUSED_VOLUMD=yes
fi

# No screensaver while we're the UI.
lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null

./bin/zkindle --todo "$DIR/todo.txt" >>"$LOG" 2>&1
log "zkindle exited with $?"
