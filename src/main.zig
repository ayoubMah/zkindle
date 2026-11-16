//! zkindle — a tiny, fast home screen for a jailbroken Kindle.
//!
//! Draws a big clock, the date, battery / Wi-Fi status and a todo list straight to the
//! e-ink framebuffer through FBInk, then sleeps in poll() until the next minute or a tap.
//!
//!   tap         -> full (flashing) refresh, clears ghosting
//!   double-tap  -> exit (run.sh then gives the screen back to the stock UI)
//!
//! Kindle gotcha: the stock kernels are old (3.x / 4.x). Zig 0.14+'s std.fs.File.stat()
//! uses statx(2), which those kernels don't have (ENOSYS). So this file never stats:
//! every read goes into a fixed buffer with plain read(2).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const c = @cImport({
    @cInclude("time.h");
    @cInclude("fbink.h");
});

// ---------------------------------------------------------------------------------------
// Options

const Options = struct {
    font_regular: [:0]const u8 = "fonts/IBMPlexMono-Regular.ttf",
    font_bold: [:0]const u8 = "fonts/IBMPlexMono-Bold.ttf",
    todo_path: []const u8 = "todo.txt",
    once: bool = false,
    full_refresh_every: u32 = 15, // minutes between flashing refreshes
};

fn parseArgs() Options {
    var o = Options{};
    var it = std.process.args();
    _ = it.skip();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--once")) {
            o.once = true;
        } else if (std.mem.eql(u8, a, "--todo")) {
            if (it.next()) |v| o.todo_path = v;
        } else if (std.mem.eql(u8, a, "--font")) {
            if (it.next()) |v| o.font_regular = v;
        } else if (std.mem.eql(u8, a, "--font-bold")) {
            if (it.next()) |v| o.font_bold = v;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\usage: zkindle [--once] [--todo PATH] [--font TTF] [--font-bold TTF]
                \\  --once   draw one frame and exit (good for testing over SSH)
                \\
            , .{});
            std.process.exit(0);
        }
    }
    return o;
}

// ---------------------------------------------------------------------------------------
// Signals

var running = std.atomic.Value(bool).init(true);

fn onSignal(_: c_int) callconv(.c) void {
    running.store(false, .monotonic);
}

fn installSignals() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.empty_sigset,
        .flags = 0, // no SA_RESTART: we *want* poll() to return EINTR
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
}

// ---------------------------------------------------------------------------------------
// System info (sysfs, no stat)

fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    var f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const n = f.read(buf) catch return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

const Battery = struct { percent: u8, charging: bool };

fn battery() ?Battery {
    // The battery node name differs per model (bd71827_bat, max77696-battery, ...),
    // so walk the power_supply class and take the first one exposing a capacity.
    var dir = std.fs.openDirAbsolute("/sys/class/power_supply", .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        var pbuf: [256]u8 = undefined;
        var vbuf: [32]u8 = undefined;
        const cap_path = std.fmt.bufPrint(&pbuf, "/sys/class/power_supply/{s}/capacity", .{e.name}) catch continue;
        const cap = readSmall(cap_path, &vbuf) orelse continue;
        const pct = std.fmt.parseInt(u8, cap, 10) catch continue;

        var sbuf: [32]u8 = undefined;
        const st_path = std.fmt.bufPrint(&pbuf, "/sys/class/power_supply/{s}/status", .{e.name}) catch continue;
        const status = readSmall(st_path, &sbuf) orelse "";
        return .{ .percent = pct, .charging = std.mem.eql(u8, status, "Charging") or std.mem.eql(u8, status, "Full") };
    }
    return null;
}

fn wifiUp() bool {
    var buf: [16]u8 = undefined;
    const s = readSmall("/sys/class/net/wlan0/operstate", &buf) orelse return false;
    return std.mem.eql(u8, s, "up");
}

// ---------------------------------------------------------------------------------------
// Drawing

const Screen = struct {
    fd: c_int,
    w: u32,
    h: u32,
    device: []const u8,
};

const Align = enum { center, left };

fn text(scr: *const Screen, cfg: *const c.FBInkConfig, s: [:0]const u8, top: u32, px: u32, bold: bool, al: Align) u32 {
    var ot = std.mem.zeroes(c.FBInkOTConfig);
    const margin: c_short = @intCast(scr.w / 14);
    ot.margins.top = @intCast(top);
    ot.margins.left = margin;
    ot.margins.right = margin;
    ot.size_px = @intCast(px);
    ot.is_centered = al == .center;
    ot.style = if (bold) c.FNT_BOLD else c.FNT_REGULAR;
    const r = c.fbink_print_ot(scr.fd, s.ptr, &ot, cfg, null);
    // On success FBInk returns the next free top margin.
    return if (r > 0) @intCast(r) else top + px + px / 3;
}

fn hline(scr: *const Screen, cfg: *const c.FBInkConfig, y: u32, thickness: u32) void {
    const m = scr.w / 14;
    const rect = c.FBInkRect{
        .left = @intCast(m),
        .top = @intCast(y),
        .width = @intCast(scr.w - 2 * m),
        .height = @intCast(thickness),
    };
    _ = c.fbink_fill_rect_gray(scr.fd, cfg, &rect, false, 0x00);
}

fn draw(scr: *const Screen, opts: *const Options, flash: bool) void {
    // Draw everything with refresh disabled, then push one refresh for the whole frame:
    // one EPDC update instead of N is what makes e-ink feel fast.
    var cfg = std.mem.zeroes(c.FBInkConfig);
    cfg.no_refresh = true;
    cfg.is_quiet = true;
    _ = c.fbink_cls(scr.fd, &cfg, null, false);

    const H = scr.h;
    var buf: [256:0]u8 = undefined;

    // ---- status line
    var status_buf: [128]u8 = undefined;
    var status: []const u8 = "";
    if (battery()) |b| {
        status = std.fmt.bufPrint(&status_buf, "{s}  ·  bat {d}%{s}  ·  wifi {s}", .{
            scr.device, b.percent, if (b.charging) "+" else "", if (wifiUp()) "on" else "off",
        }) catch "";
    } else {
        status = std.fmt.bufPrint(&status_buf, "{s}  ·  wifi {s}", .{ scr.device, if (wifiUp()) "on" else "off" }) catch "";
    }
    var y: u32 = H / 30;
    y = text(scr, &cfg, toZ(&buf, status), y, H / 48, false, .center);

    // ---- clock + date
    var now: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now, &tm);

    var clock: [16:0]u8 = undefined;
    const clen = c.strftime(&clock, clock.len, "%H:%M", &tm);
    clock[clen] = 0;
    y = text(scr, &cfg, clock[0..clen :0], H / 8, H / 5, true, .center);

    var date: [64:0]u8 = undefined;
    const dlen = c.strftime(&date, date.len, "%A %d %B %Y", &tm);
    date[dlen] = 0;
    y = text(scr, &cfg, date[0..dlen :0], y, H / 30, false, .center);

    y += H / 30;
    hline(scr, &cfg, y, 3);
    y += H / 30;

    // ---- todo list
    y = text(scr, &cfg, "today", y, H / 34, true, .left);
    var todo_buf: [4096]u8 = undefined;
    const todo = readTodo(opts.todo_path, &todo_buf);
    const line_px = H / 38;
    var lines = std.mem.tokenizeAny(u8, todo, "\r\n");
    var count: u32 = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (y + line_px * 2 > H - H / 10) break; // keep room for the footer
        const shown = std.fmt.bufPrint(&buf, "- {s}", .{line}) catch continue;
        buf[shown.len] = 0;
        y = text(scr, &cfg, buf[0..shown.len :0], y + line_px / 3, line_px, false, .left);
        count += 1;
    }
    if (count == 0) {
        y = text(scr, &cfg, "(edit todo.txt in the extension folder)", y + line_px / 3, line_px, false, .left);
    }

    // ---- footer
    _ = text(scr, &cfg, "tap: refresh   ·   double-tap: exit", H - H / 14, H / 56, false, .center);

    // ---- one refresh for the whole frame
    var rcfg = std.mem.zeroes(c.FBInkConfig);
    rcfg.is_flashing = flash;
    rcfg.wfm_mode = if (flash) c.WFM_GC16 else c.WFM_AUTO;
    _ = c.fbink_refresh(scr.fd, 0, 0, 0, 0, &rcfg);
}

fn toZ(buf: *[256:0]u8, s: []const u8) [:0]const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

fn readTodo(path: []const u8, buf: []u8) []const u8 {
    var f = std.fs.cwd().openFile(path, .{}) catch return "";
    defer f.close();
    var total: usize = 0;
    while (total < buf.len) {
        const n = f.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

// ---------------------------------------------------------------------------------------
// Touch input (raw evdev)

// struct input_event on 32-bit ARM: {u32 sec, u32 usec, u16 type, u16 code, s32 value}.
// usize keeps it right on a 64-bit host build too.
const InputEvent = extern struct { sec: usize, usec: usize, type: u16, code: u16, value: i32 };

const EV_KEY = 0x01;
const EV_ABS = 0x03;
const BTN_TOUCH = 0x14a;
const ABS_MT_TRACKING_ID = 0x39;
const EVIOCGRAB: u32 = 0x40044590; // _IOW('E', 0x90, int)

const Touch = struct {
    down: bool = false,

    /// Feed one event; returns true when a finger was lifted (i.e., a tap ended).
    fn feed(self: *Touch, ev: InputEvent) bool {
        const pressed: ?bool = switch (ev.type) {
            EV_KEY => if (ev.code == BTN_TOUCH) ev.value != 0 else null,
            EV_ABS => if (ev.code == ABS_MT_TRACKING_ID) ev.value >= 0 else null,
            else => null,
        };
        const p = pressed orelse return false;
        defer self.down = p;
        return self.down and !p;
    }
};

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

// ---------------------------------------------------------------------------------------

pub fn main() !void {
    const opts = parseArgs();
    installSignals();

    const fd = c.fbink_open();
    if (fd < 0) {
        std.debug.print("zkindle: can't open the framebuffer (are you root?)\n", .{});
        return error.FramebufferOpen;
    }
    defer _ = c.fbink_close(fd);

    var cfg = std.mem.zeroes(c.FBInkConfig);
    cfg.is_quiet = true;
    if (c.fbink_init(fd, &cfg) < 0) return error.FramebufferInit;

    var st = std.mem.zeroes(c.FBInkState);
    c.fbink_get_state(&cfg, &st);

    if (c.fbink_add_ot_font(opts.font_regular.ptr, c.FNT_REGULAR) < 0 or
        c.fbink_add_ot_font(opts.font_bold.ptr, c.FNT_BOLD) < 0)
    {
        std.debug.print("zkindle: can't load fonts ({s}, {s})\n", .{ opts.font_regular, opts.font_bold });
        return error.FontLoad;
    }
    defer _ = c.fbink_free_ot_fonts();

    const scr = Screen{
        .fd = fd,
        .w = st.view_width,
        .h = st.view_height,
        .device = std.mem.sliceTo(&st.device_name, 0),
    };
    std.debug.print("zkindle: {s} ({s}) {d}x{d} @ {d}bpp\n", .{
        scr.device, std.mem.sliceTo(&st.device_codename, 0), scr.w, scr.h, st.bpp,
    });

    draw(&scr, &opts, true);
    if (opts.once) return;

    // ---- find & grab the touchscreen(s)
    var ndev: usize = 0;
    const devs = c.fbink_input_scan(c.INPUT_TOUCHSCREEN, 0, c.NO_RECAP, &ndev);
    defer if (devs != null) std.c.free(devs);

    var pfds_buf: [8]posix.pollfd = undefined;
    var npfd: usize = 0;
    if (devs != null) {
        for (devs[0..ndev]) |d| {
            if (!d.matched or d.fd < 0 or npfd == pfds_buf.len) continue;
            _ = linux.ioctl(d.fd, EVIOCGRAB, 1); // stop the stock UI from also seeing our taps
            pfds_buf[npfd] = .{ .fd = d.fd, .events = posix.POLL.IN, .revents = 0 };
            npfd += 1;
            std.debug.print("zkindle: touch input on {s} ({s})\n", .{
                std.mem.sliceTo(&d.path, 0), std.mem.sliceTo(&d.name, 0),
            });
        }
    }
    defer for (pfds_buf[0..npfd]) |p| posix.close(p.fd);

    // Safety net: without a touchscreen there's no way to exit, so bail out after a minute.
    const no_touch_deadline: ?i64 = if (npfd == 0) nowMs() + 60_000 else null;
    if (npfd == 0) std.debug.print("zkindle: no touchscreen found, exiting in 60s\n", .{});

    var touch = [_]Touch{.{}} ** 8;
    var last_tap: i64 = -100_000;
    var pending_refresh_at: ?i64 = null;
    var minutes: u32 = 0;
    const double_tap_ms = 450;

    while (running.load(.monotonic)) {
        const t = nowMs();
        if (no_touch_deadline) |dl| if (t >= dl) break;

        // Sleep until the next minute boundary, or until a pending single-tap refresh is due.
        var wake = t + (60_000 - @mod(t, 60_000)) + 20;
        if (pending_refresh_at) |p| wake = @min(wake, p);
        if (no_touch_deadline) |dl| wake = @min(wake, dl);
        const timeout: i32 = @intCast(@max(0, wake - t));

        const rc = linux.poll(&pfds_buf, @intCast(npfd), timeout);
        if (linux.E.init(rc) == .INTR) continue;

        const t2 = nowMs();
        var ready: usize = 0;
        if (linux.E.init(rc) == .SUCCESS) ready = rc;

        if (ready > 0) {
            for (pfds_buf[0..npfd], 0..) |p, i| {
                if (p.revents & posix.POLL.IN == 0) continue;
                var evs: [64]InputEvent = undefined;
                while (true) {
                    const n = posix.read(p.fd, std.mem.sliceAsBytes(&evs)) catch break;
                    if (n == 0) break;
                    for (evs[0 .. n / @sizeOf(InputEvent)]) |ev| {
                        if (!touch[i].feed(ev)) continue;
                        if (t2 - last_tap < double_tap_ms) {
                            running.store(false, .monotonic);
                        } else {
                            last_tap = t2;
                            pending_refresh_at = t2 + double_tap_ms;
                        }
                    }
                }
            }
            continue;
        }

        if (pending_refresh_at) |p| if (t2 >= p) {
            pending_refresh_at = null;
            draw(&scr, &opts, true);
            continue;
        };

        // Minute tick: fast partial refresh, with a periodic flash to clear ghosting.
        minutes += 1;
        draw(&scr, &opts, minutes % opts.full_refresh_every == 0);
    }

    std.debug.print("zkindle: bye\n", .{});
}
