#!/bin/sh
# Fetch FBInk and only the submodules zkindle needs (the i2c-tools/libevdev ones are Kobo-only).
set -eu
cd "$(dirname "$0")/.."
mkdir -p vendor
if [ ! -d vendor/FBInk/.git ]; then
    git clone --depth 1 https://github.com/NiLuJe/FBInk.git vendor/FBInk
fi
cd vendor/FBInk
git submodule update --init --depth 1 font8x8 stb libunibreak
echo "FBInk ready at $(git rev-parse --short HEAD)"
