# zkindle

A small, fast home screen for a jailbroken Kindle, written in **Zig**. It shows a large clock, the date, battery and Wi-Fi status, and a todo list. It draws straight to the e-ink framebuffer and sends one refresh per frame.

- **Drawing:** [FBInk](https://github.com/NiLuJe/FBInk) by NiLuJe. `build.zig` compiles it from C source. FBInk knows the refresh ioctls for every Kindle generation (i.MX `mxcfb` on older models, MediaTek `hwtcon` on PW5 and later).
- **Binary:** one static musl ARMv7 file, about 1.2 MB. It has no glibc dependency, so it runs on both soft-float and hard-float (5.16.3+) firmware.
- **Launcher:** a [KUAL](https://kindlemodding.org/) menu entry. `run.sh` pauses the stock UI the same way KOReader does, and restores it when zkindle exits.

**Controls:** tap = full refresh (clears ghosting). Double-tap = exit back to the Kindle home screen.

---

## 0. Check your Kindle first

On the Kindle, open **Settings → Device Options → Device Info** and write down the **model** and **firmware version**.

Turn on **airplane mode now** and leave it on until the jailbreak is done. Amazon patches each jailbreak in the next firmware update, and you can't downgrade.

Which jailbreak to use depends on your firmware. Use the **Jailbreaking Wizard** on <https://kindlemodding.org>. It picks the right method for your model and build number. As of November 2026:

| Method | Firmware | Notes |
|---|---|---|
| **Shadow** (Oct 2026) | wizard decides | Runs from a PC over USB. The Kindle never goes online, so no filler files are needed. |
| **Véra** (Aug 2026) | up to 5.19.6 | Latest two generations |
| **SpiderCat** (Sep 2026) | 5.16.3 – 5.19.5 | You open a book file. Patched in 5.19.6. |
| **Sanctuary** (Jun 2026) | 5.16.4 – 5.18.3 | Runs in the Kindle's own browser |
| WinterBreak / AdBreak / LanguageBreak / WatchThis | older firmware | Legacy paths |

3rd-gen Kindle Scribe and Scribe Colorsoft had no jailbreak as of August 2026.

## 1. Jailbreak and post-jailbreak setup

Follow the wizard's guide for your method. Then, as the kindlemodding.org guide says:

1. Install the **hotfix**, so the jailbreak survives firmware updates.
2. Install **KUAL** (the app launcher) and **MRPI** (the package installer).
3. **Block OTA updates**, so Amazon can't undo the jailbreak. After that you can turn Wi-Fi back on.
4. Optional, but very useful for development: **USBNetLite** or KOReader's SSH server, so you can `ssh root@<kindle>`.

## 2. Build

You need **Zig 0.14.1** (from ziglang.org, `winget install zig.zig`, or `pip install ziglang==0.14.1`) and git.

```sh
./scripts/fetch-deps.sh              # PowerShell: .\scripts\fetch-deps.ps1
zig build package
```

The output is the KUAL extension folder `zig-out/extensions/zkindle/` (plus `zig-out/zkindle-kual.zip` on Linux/macOS).

Other build commands:

```sh
zig build                                   # just the binary -> zig-out/bin/zkindle
zig build -Doptimize=Debug                  # debug build (bigger, has symbols)
zig build -Dplatform=linux -Dtarget=native  # host build against a Linux /dev/fb0
```

## 3. Install

1. Plug the Kindle into USB.
2. Copy `zig-out/extensions/zkindle/` to `extensions/` on the Kindle's drive. You should end up with `extensions/zkindle/run.sh`.
3. Edit `extensions/zkindle/todo.txt`: one item per line; lines starting with `#` are ignored.
4. Eject the Kindle, open **KUAL → zkindle → Start zkindle**.

Try **"Draw one frame (test)"** first. It draws a single frame, waits 6 seconds, then returns to the home screen. Logs are written to `extensions/zkindle/zkindle.log`.

If the clock shows UTC instead of your local time, create `extensions/zkindle/tz` containing a POSIX TZ string. For Paris: `CET-1CEST,M3.5.0,M10.5.0/3`

## Fast dev loop (over SSH)

```sh
zig build && scp zig-out/bin/zkindle root@kindle:/mnt/us/extensions/zkindle/bin/
ssh root@kindle 'cd /mnt/us/extensions/zkindle && ./bin/zkindle --once'
```

`--once` draws a frame and exits, without pausing the stock UI. The stock UI will draw over it again soon, but that's enough to check layout changes quickly.

## Kindle gotchas this project already handles

- **Old kernels have no `statx`.** Zig ≥ 0.14's `std.fs.File.stat()` (and anything built on it, such as `readToEndAlloc`) calls `statx(2)`. On a Kindle's 3.x/4.x kernel that returns `ENOSYS`. zkindle never calls stat; it reads files into fixed buffers with plain `read(2)`. Keep doing that, or keep checking with `qemu-arm-static -strace ./zkindle --once 2>&1 | grep statx`.
- **The stock UI keeps repainting.** `run.sh` disables pillow (the status bar), SIGSTOPs `awesome` (the window manager), stops the `statusbar` job on newer firmware, and pauses `volumd`. A trap reverses all of it on exit, even if zkindle crashes.
- **Ghosting vs speed.** zkindle redraws every minute with a fast non-flashing refresh, and does a full GC16 flash every 15 minutes or when you tap.
- **Taps leaking to the stock UI.** zkindle takes an exclusive `EVIOCGRAB` on the touchscreen while it runs.
- **Getting stuck.** If no touchscreen is found, zkindle exits by itself after 60 seconds. As a last resort, hold the power button for about 40 seconds to force a reboot.

## Layout

```
build.zig            FBInk (C) + zkindle (Zig) + package step
src/main.zig         the app: draw(), sysfs readers, evdev tap handling, poll loop
kual/zkindle/        KUAL extension: config.xml, menu.json, run.sh, todo.txt
assets/fonts/        IBM Plex Mono (SIL OFL, see OFL.txt)
scripts/             fetch FBInk + only the submodules we need
```

## Ideas for next steps

- Show data pulled from your own server (calendar, CI status, Home Assistant). The Kindle has Wi-Fi and `std.http.Client` works, but load CA certs without `stat` (see the gotcha above).
- Tap zones, using the touch coordinates (`ABS_MT_POSITION_X/Y`, already read via evdev).
- Images with `fbink_print_image` (FBInk is built with image support).
- Replace the KUAL launch with a boot-time upstart job so zkindle becomes the real home screen.

License: GPLv3+, because FBInk (GPLv3+) is statically linked.

Credits: FBInk by NiLuJe (GPLv3+). The launcher logic is adapted from KOReader's `platform/kindle/koreader.sh` (AGPLv3). The Kindle modding community at kindlemodding.org and MobileRead.
