#!/bin/sh
# zkindle launcher. Started by the "zkindle" scriptlet in your library, or over SSH:
#   /mnt/us/zkindle/run.sh          start zkindle (detaches itself, returns immediately)
#   /mnt/us/zkindle/run.sh --test   draw one frame, then go back to the home screen
#
# Pauses the stock Kindle UI so it doesn't draw over us, starts the widget fetcher,
# runs zkindle, then puts everything back. The UI-pausing approach mirrors KOReader's
# platform/kindle/koreader.sh (the "framework stays up" path).

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/zkindle.log"
cd "$DIR" || exit 1

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# If the clock shows UTC, put a POSIX TZ string in a file named "tz" next to this
# script, e.g. for Paris:  CET-1CEST,M3.5.0,M10.5.0/3
[ -f "$DIR/tz" ] && export TZ="$(cat "$DIR/tz")"

MODE="run"
[ "$1" = "--test" ] && MODE="test"

# Detach from whatever started us (an SSH session, a scriptlet) so that closing it
# can't take zkindle down with it and leave the stock UI frozen.
if [ "$MODE" = "run" ] && [ -z "$ZK_DETACHED" ] && command -v setsid >/dev/null 2>&1; then
    ZK_DETACHED=1 setsid "$0" "$@" </dev/null >/dev/null 2>&1 &
    exit 0
fi

# Give the library a moment to settle after the scriptlet tap, otherwise it can repaint over us.
usleep 500000 2>/dev/null || sleep 1

# Keep the log small: it gets a line per minute.
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 200000 ]; then
    tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

if [ "$MODE" = "test" ]; then
    log "test: drawing one frame"
    ./bin/zkindle --once >>"$LOG" 2>&1
    sleep 6
    lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home
    exit 0
fi

PIDFILE=/var/tmp/zkindle.pid
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "already running (pid $(cat "$PIDFILE")), not starting twice"
    exit 0
fi
echo $$ >"$PIDFILE"

PAUSED_AWESOME=no
STOPPED_STATUSBAR=no
FETCH_PID=

restore() {
    log "restoring stock UI"
    [ -n "$FETCH_PID" ] && kill "$FETCH_PID" 2>/dev/null
    rm -f "$PIDFILE"
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
trap 'log "launcher got SIGTERM"; exit 0' TERM
trap 'log "launcher got SIGINT"; exit 0' INT
trap 'log "launcher got SIGHUP"; exit 0' HUP

log "starting pid $$ ($(cat /etc/prettyversion.txt 2>/dev/null))"

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

# Note: KOReader also pauses volumd, but on MTP-era Kindles (KT6, /mnt/us is "fsp")
# that's not needed and risks stalling access to /mnt/us, where our log and todo live.

# No screensaver while we're the UI.
lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null

# Widget data (weather, GitHub) in the background; zkindle reads cache/ each minute.
./fetch.sh >/dev/null 2>&1 &
FETCH_PID=$!

./bin/zkindle --todo "$DIR/todo.txt" >>"$LOG" 2>&1
log "zkindle exited with $?"
