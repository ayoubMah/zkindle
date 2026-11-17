#!/bin/sh
# Run once after copying/unpacking zkindle to /mnt/us/zkindle (safe to re-run on upgrades).
# - creates zkindle.conf and todo.txt from defaults/ only if you don't have them yet
# - puts the two scriptlets in your library (/mnt/us/documents)
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
for f in zkindle.conf todo.txt; do
    if [ ! -f "$f" ]; then cp "defaults/$f" "$f"; echo "created $f"; else echo "kept your $f"; fi
done
[ -f tz ] || { echo 'CET-1CEST,M3.5.0,M10.5.0/3' >tz; echo "created tz (Paris time; edit if you're elsewhere)"; }
mkdir -p cache wallpapers /mnt/us/documents
chmod +x bin/zkindle run.sh fetch.sh saver.sh
cp scriptlets/zkindle.sh scriptlets/zkindle-screensaver.sh /mnt/us/documents/
echo "scriptlets installed: look for 'zkindle' and 'zkindle screensaver on-off' in your library"
