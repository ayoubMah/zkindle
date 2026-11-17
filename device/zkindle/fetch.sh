#!/bin/sh
# zkindle widget fetcher: downloads weather + GitHub activity into cache/ while Wi-Fi is up.
# zkindle itself never touches the network; it just reads these files.
#
#   ./fetch.sh          loop forever (started by run.sh, stopped when zkindle exits)
#   ./fetch.sh --once   fetch once and exit (handy for testing over SSH)

DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE="$DIR/cache"
mkdir -p "$CACHE"

conf() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$DIR/zkindle.conf" 2>/dev/null |
        sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' | head -n 1
}

# get URL FILE: download to FILE.tmp, then rename, so zkindle never reads half a file.
get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -m 25 -A "zkindle" "$1" -o "$2.tmp" && mv "$2.tmp" "$2"
    else
        wget -q -T 25 -U "zkindle" -O "$2.tmp" "$1" && mv "$2.tmp" "$2"
    fi
    rc=$?
    rm -f "$2.tmp"
    return $rc
}

while :; do
    CITY="$(conf city | sed 's/ /+/g')"
    GH="$(conf github_user)"

    if [ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = "up" ]; then
        if [ -n "$CITY" ]; then
            # e.g. "Partly cloudy, +8°C (feels +6°C), 81% humidity"
            get "https://wttr.in/$CITY?m&format=%C,+%t+(feels+%f),+%h+humidity" "$CACHE/weather.txt" ||
                echo "$(date '+%T') fetch: weather failed" >>"$DIR/zkindle.log"
        fi
        if [ -n "$GH" ]; then
            get "https://api.github.com/users/$GH/events/public?per_page=50" "$CACHE/github.json" ||
                echo "$(date '+%T') fetch: github failed" >>"$DIR/zkindle.log"
        fi
    fi

    [ "$1" = "--once" ] && exit 0
    sleep 1800
done
