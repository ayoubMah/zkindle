#!/bin/sh
# zkindle screensaver: whenever the Kindle goes to sleep, draw our own sleep screen
# (a wallpaper + "sleeping since HH:MM") over Amazon's, then let it suspend.
# Nothing on the system partition is modified; it's just a background listener.
#
#   ./saver.sh on | off | toggle | status
#
# The listener doesn't survive a reboot: run the "zkindle screensaver" scriptlet again after one.

DIR="$(cd "$(dirname "$0")" && pwd)"
PIDFILE=/var/tmp/zkindle-saver.pid
LOG="$DIR/zkindle.log"

is_on() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "$1" in
    on)
        if is_on; then echo "zkindle screensaver: already on"; exit 0; fi
        setsid "$0" daemon </dev/null >/dev/null 2>&1 &
        echo "zkindle screensaver: ON"
        ;;
    off)
        if is_on; then kill "$(cat "$PIDFILE")"; fi
        rm -f "$PIDFILE"
        echo "zkindle screensaver: OFF"
        ;;
    toggle)
        if is_on; then "$0" off; else "$0" on; fi
        ;;
    status)
        if is_on; then echo "zkindle screensaver: on"; else echo "zkindle screensaver: off"; fi
        ;;
    daemon)
        echo $$ >"$PIDFILE"
        trap 'rm -f "$PIDFILE"; exit 0' TERM INT
        cd "$DIR" || exit 1
        [ -f "$DIR/tz" ] && export TZ="$(cat "$DIR/tz")"
        echo "$(date '+%F %T') saver: listening" >>"$LOG"
        while :; do
            # Blocks until the device starts going to sleep (power button or timeout).
            if ! lipc-wait-event com.lab126.powerd goingToScreenSaver >/dev/null 2>&1; then
                sleep 10
                continue
            fi
            # Let the stock screensaver draw first, then draw over it before suspend.
            sleep 2
            "$DIR/bin/zkindle" --saver >>"$LOG" 2>&1
        done
        ;;
    *)
        echo "usage: $0 on|off|toggle|status"
        exit 1
        ;;
esac
