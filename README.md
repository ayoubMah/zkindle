# zkindle

A small, fast home screen for a jailbroken Kindle, written in **Zig**. It shows a clock, the date, battery and Wi-Fi status, widgets (weather, GitHub activity, a countdown, a quote of the day) and your todo list, drawn over rotating wallpapers. There are three layouts, a light and a dark theme, and a custom screensaver.

- **Drawing:** [FBInk](https://github.com/NiLuJe/FBInk) by NiLuJe, compiled from C source by `build.zig`. Text, wallpapers and cards are drawn first, then the whole frame gets **one** e-ink refresh.
- **Binary:** one static musl ARMv7 file, about 1.3 MB. It runs on soft-float and hard-float firmware alike.
- **Launching:** a **scriptlet** in your library. Tap "zkindle" like a book. (KUAL doesn't work on the modern jailbreaks.)
- **Tested on:** Kindle 11th gen 2024 (KT6, "Basic 5 / Rossini"), firmware 5.20.1, jailbroken with Véra.

## Controls

| Tap | Does |
|---|---|
| top quarter | next layout: dashboard → classic → minimal |
| middle | full refresh (clears ghosting) |
| bottom quarter | light ↔ dark theme |
| double-tap anywhere | exit back to the Kindle home screen |

Layout and theme are remembered in the `state` file. Delete it to go back to what `zkindle.conf` says.

## Install

You need a jailbroken Kindle and SSH (Jobman → SSH & USB Networking → Wi-Fi SSH, password `kindle`).

```powershell
# on the PC (download zkindle.tar.gz from Releases/Actions, or build it, see below)
scp zkindle.tar.gz root@<kindle-ip>:/mnt/us/
```
```sh
# on the Kindle (ssh root@<kindle-ip>)
cd /mnt/us && tar -xzf zkindle.tar.gz && rm zkindle.tar.gz && sh zkindle/install.sh
```

`install.sh` is safe to re-run on upgrades. It keeps your `zkindle.conf`, `todo.txt` and `tz`, and puts two scriptlets in your library:

- **zkindle**: starts the home screen.
- **zkindle screensaver on-off**: turns the custom sleep screen on or off. Run it again after a reboot.

## Customize (`/mnt/us/zkindle/`, over USB or SSH)

| File | What |
|---|---|
| `zkindle.conf` | theme, layout, wallpaper rotation, weather city, GitHub user, countdown, refresh cadence |
| `todo.txt` | one item per line |
| `quotes.txt` | one quote per line, a different one each day |
| `wallpapers/` | your PNG/JPG images. 1072×1448 grayscale looks best on a KT6; others are scaled to fit |
| `tz` | POSIX time zone, e.g. `CET-1CEST,M3.5.0,M10.5.0/3` for Paris |

Weather (wttr.in) and GitHub activity are downloaded by `fetch.sh` every 30 minutes while Wi-Fi is on. zkindle itself never uses the network; it only reads `cache/`.

## Build

You need **Zig 0.14.1** and git.

```sh
./scripts/fetch-deps.sh        # PowerShell: .\scripts\fetch-deps.ps1
zig build test                 # unit tests (config parser, widget logic) on your machine
zig build package              # -> zig-out/zkindle.tar.gz and zig-out/zkindle/
```

Fast dev loop:
```sh
zig build && scp zig-out/bin/zkindle root@<kindle-ip>:/mnt/us/zkindle/bin/
ssh root@<kindle-ip> 'cd /mnt/us/zkindle && ./bin/zkindle --once'      # or --saver
```

## Jailbreaking (short version)

1. Note your model and firmware: **Settings → Device Options → Device Info**. Turn **airplane mode on**, and leave it on until the jailbreak is done.
2. Find your method with the wizard on <https://kindlemodding.org>. For a KT6 on 5.20.1, that's **Véra**.
3. Fill the storage first, so the Kindle can't download an update while online. On MTP Kindles (11th gen+), copy the `fill_*` files from [Kindle-Filler-Disk/MTP](https://github.com/Crosunt223/Kindle-Filler-Disk/tree/main/MTP) until only 50–90 MB is free.
4. Follow the Véra guide: open the browser, go to `kindlemodding.org/vera`, download the two books, set up the font theme, then open the Véra book.
5. Afterwards: `;kpm update` then `;kpm install jobman` in the search bar. In Jobman, check that **OTA updates are disabled**, then delete the filler files.

## Kindle gotchas this project handles

- **No `statx` on old kernels.** The KT6 runs Linux 4.9, and `statx(2)` only appeared in 4.11. Zig ≥ 0.14's `std.fs.File.stat()` (and so `readToEndAlloc` and friends) fails on it. zkindle never stats: reads go into fixed buffers with `read(2)`. To check: `qemu-arm-static -strace ./zkindle --once 2>&1 | grep statx`.
- **The stock UI keeps repainting.** `run.sh` disables pillow, SIGSTOPs `awesome` and stops the `statusbar` job, and a trap undoes all of it on exit.
- **Firmware 5.20 kills the foreground app while `awesome` is paused**, together with everything it started (including Jobman's SSH server). `run.sh` therefore re-launches itself under `setsid`, so zkindle survives.
- **Don't pause `volumd` on MTP Kindles.** `/mnt/us` is `fsp` there, and pausing it can stall the storage where the log and todo live.
- **Speed.** The decoded wallpaper is kept as a framebuffer dump, so a minute tick is a memcpy plus text, refreshed with a fast non-flashing update. A full GC16 flash happens every `flash_every` minutes, or when you tap.
- **Taps leaking to the stock UI.** zkindle takes an exclusive `EVIOCGRAB` on the touchscreen.
- **Getting stuck.** Hold the power button for about 40 s to reboot. Nothing on the system partition is modified.

## Layout

```
build.zig              FBInk (C) + zkindle (Zig) + tests + package step
src/main.zig           rendering, layouts, wallpapers, touch zones, main loop
src/config.zig         zkindle.conf / state parser (tested)
src/widgets.zig        countdown, quote picker, GitHub summary (tested)
device/zkindle/        what lands in /mnt/us/zkindle: run.sh, fetch.sh, saver.sh, install.sh,
                       defaults/, scriptlets/, wallpapers/, quotes.txt, icons
assets/fonts/          IBM Plex Mono (SIL OFL, see OFL.txt)
```

License: GPLv3+, because FBInk (GPLv3+) is statically linked.

Credits: FBInk by NiLuJe (GPLv3+). The UI-pausing logic is adapted from KOReader's `platform/kindle/koreader.sh` (AGPLv3). Véra by Ava & sparklerfish, Jobman by KindleTweaks, and the KindleModding community.
