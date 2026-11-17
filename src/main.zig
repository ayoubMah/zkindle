//! zkindle: a small, fast home screen for a jailbroken Kindle, written in Zig.
//!
//! Draws a clock, date, status, widgets and a todo list over an optional wallpaper,
//! straight to the e-ink framebuffer through FBInk, then sleeps in poll() until the
//! next minute or a tap.
//!
//!   tap top quarter     -> next layout (dashboard / classic / minimal)
//!   tap middle          -> full (flashing) refresh, clears ghosting
//!   tap bottom quarter  -> toggle light / dark theme
//!   double-tap anywhere -> exit (run.sh then gives the screen back to the stock UI)
//!
//!   zkindle --once      draw one frame and exit
//!   zkindle --saver     draw the screensaver frame and exit (used by saver.sh)
//!
//! Kindle gotcha: the stock kernels are old (KT6: 4.9). Zig 0.14+'s std.fs.File.stat()
//! uses statx(2), which only exists since Linux 4.11, so this program never stats:
//! every read goes into a fixed buffer with plain read(2).

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const config = @import("config.zig");
const widgets = @import("widgets.zig");

const c = @cImport({
    @cInclude("time.h");
    @cInclude("fbink.h");
});

// ---------------------------------------------------------------------------------------
// Options

const Mode = enum { run, once, saver };

const Options = struct {
    mode: Mode = .run,
    conf_path: []const u8 = "zkindle.conf",
    todo_path: []const u8 = "todo.txt",
    font_regular: [:0]const u8 = "fonts/IBMPlexMono-Regular.ttf",
    font_bold: [:0]const u8 = "fonts/IBMPlexMono-Bold.ttf",
};

fn parseArgs() Options {
    var o = Options{};
    var it = std.process.args();
    _ = it.skip();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--once")) {
            o.mode = .once;
        } else if (std.mem.eql(u8, a, "--saver")) {
            o.mode = .saver;
        } else if (std.mem.eql(u8, a, "--conf")) {
            if (it.next()) |v| o.conf_path = v;
        } else if (std.mem.eql(u8, a, "--todo")) {
            if (it.next()) |v| o.todo_path = v;
        } else if (std.mem.eql(u8, a, "--font")) {
            if (it.next()) |v| o.font_regular = v;
        } else if (std.mem.eql(u8, a, "--font-bold")) {
            if (it.next()) |v| o.font_bold = v;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\usage: zkindle [--once | --saver] [--conf PATH] [--todo PATH] [--font TTF] [--font-bold TTF]
                \\  --once    draw one frame and exit (good for testing over SSH)
                \\  --saver   draw the screensaver frame and exit
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
var last_signal = std.atomic.Value(c_int).init(0);

fn onSignal(sig: c_int) callconv(.c) void {
    last_signal.store(sig, .monotonic);
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
// Files (no stat!)

fn readInto(path: []const u8, buf: []u8) []u8 {
    var f = std.fs.cwd().openFile(path, .{}) catch return buf[0..0];
    defer f.close();
    var total: usize = 0;
    while (total < buf.len) {
        const n = f.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    var f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const n = f.read(buf) catch return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn firstLine(s: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, s, "\r\n") orelse s.len;
    return std.mem.trim(u8, s[0..end], " \t");
}

// ---------------------------------------------------------------------------------------
// Config + state

var conf_text: [8192]u8 = undefined;
var state_text: [512]u8 = undefined;

fn loadConfig(opts: *const Options) config.Config {
    var cfg = config.Config{};
    config.apply(&cfg, readInto(opts.conf_path, &conf_text));
    // Layout/theme picked with taps win over zkindle.conf. Delete `state` to reset.
    config.apply(&cfg, readInto("state", &state_text));
    return cfg;
}

fn saveState(cfg: config.Config) void {
    var buf: [128]u8 = undefined;
    const s = config.formatState(&buf, cfg);
    var f = std.fs.cwd().createFile("state", .{}) catch return;
    defer f.close();
    f.writeAll(s) catch {};
}

// ---------------------------------------------------------------------------------------
// System info (sysfs)

const Battery = struct { percent: u8, charging: bool };

fn battery() ?Battery {
    // The battery node name differs per model (bd71828_bat on KT6, max77696-battery, ...),
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
// Wallpapers

const Wallpapers = struct {
    const max = 64;
    names: [max][128]u8 = undefined,
    lens: [max]usize = undefined,
    n: usize = 0,

    fn isImage(file: []const u8) bool {
        const exts = [_][]const u8{ ".png", ".jpg", ".jpeg" };
        for (exts) |ext| {
            if (file.len > ext.len and std.ascii.eqlIgnoreCase(file[file.len - ext.len ..], ext)) return true;
        }
        return false;
    }

    fn scan(self: *Wallpapers, dir_path: []const u8) void {
        self.n = 0;
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (self.n == max or e.name.len > 127 or e.name[0] == '.' or !isImage(e.name)) continue;
            @memcpy(self.names[self.n][0..e.name.len], e.name);
            self.lens[self.n] = e.name.len;
            self.n += 1;
        }
        // Insertion sort by name, so the rotation order is predictable (01-foo.png, 02-bar.jpg, ...).
        var i: usize = 1;
        while (i < self.n) : (i += 1) {
            var j = i;
            while (j > 0 and std.mem.order(u8, self.name(j), self.name(j - 1)) == .lt) : (j -= 1) {
                std.mem.swap([128]u8, &self.names[j], &self.names[j - 1]);
                std.mem.swap(usize, &self.lens[j], &self.lens[j - 1]);
            }
        }
    }

    fn name(self: *const Wallpapers, i: usize) []const u8 {
        return self.names[i][0..self.lens[i]];
    }

    fn path(self: *const Wallpapers, dir_path: []const u8, i: usize, buf: []u8) ?[:0]const u8 {
        const s = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir_path, self.name(i) }) catch return null;
        return s;
    }
};

// ---------------------------------------------------------------------------------------
// Rendering

const Screen = struct {
    fd: c_int,
    w: u32,
    h: u32,
    device: []const u8,
    touch_swap_axes: bool,
    touch_mirror_x: bool,
    touch_mirror_y: bool,
};

const Pen = struct {
    scr: *const Screen,
    dark: bool,
    cards: bool,

    fn fgGray(self: Pen) u8 {
        return if (self.dark) 0xFF else 0x00;
    }
    fn bgGray(self: Pen) u8 {
        return if (self.dark) 0x00 else 0xFF;
    }
    fn margin(self: Pen) u32 {
        return self.scr.w / 14;
    }

    fn baseCfg(self: Pen) c.FBInkConfig {
        var k = std.mem.zeroes(c.FBInkConfig);
        k.no_refresh = true;
        k.is_quiet = true;
        k.is_bgless = true; // we paint our own backgrounds (cards), so text never boxes the wallpaper
        k.fg_color = if (self.dark) c.FG_WHITE else c.FG_BLACK;
        k.bg_color = if (self.dark) c.BG_BLACK else c.BG_WHITE;
        return k;
    }

    fn otCfg(px: u32, bold: bool, center: bool, top: u32, left: u32, right: u32) c.FBInkOTConfig {
        var ot = std.mem.zeroes(c.FBInkOTConfig);
        ot.margins.top = @intCast(top);
        ot.margins.left = @intCast(left);
        ot.margins.right = @intCast(right);
        ot.size_px = @intCast(px);
        ot.is_centered = center;
        ot.style = if (bold) c.FNT_BOLD else c.FNT_REGULAR;
        return ot;
    }

    /// Height in pixels the string will take, line-wrapped between the margins.
    fn measure(self: Pen, s: []const u8, px: u32, bold: bool, center: bool, left: u32, right: u32) u32 {
        var zbuf: [512:0]u8 = undefined;
        const z = toZ(&zbuf, s);
        var ot = otCfg(px, bold, center, 0, left, right);
        ot.compute_only = true;
        var fit = std.mem.zeroes(c.FBInkOTFit);
        const k = self.baseCfg();
        if (c.fbink_print_ot(self.scr.fd, z.ptr, &ot, &k, &fit) < 0 or fit.bbox.height == 0) {
            return px + px / 3; // fall back to one line
        }
        return fit.bbox.height;
    }

    fn print(self: Pen, s: []const u8, px: u32, bold: bool, center: bool, top: u32, left: u32, right: u32) void {
        var zbuf: [512:0]u8 = undefined;
        const z = toZ(&zbuf, s);
        var ot = otCfg(px, bold, center, top, left, right);
        const k = self.baseCfg();
        _ = c.fbink_print_ot(self.scr.fd, z.ptr, &ot, &k, null);
    }

    fn rect(self: Pen, x: u32, y: u32, w: u32, h: u32, gray: u8) void {
        if (w == 0 or h == 0) return;
        const r = c.FBInkRect{ .left = @intCast(x), .top = @intCast(y), .width = @intCast(w), .height = @intCast(h) };
        const k = self.baseCfg();
        _ = c.fbink_fill_rect_gray(self.scr.fd, &k, &r, false, gray);
    }

    const Item = struct {
        s: []const u8,
        px: u32,
        bold: bool = false,
        center: bool = false,
    };

    fn padX(self: Pen) u32 {
        return if (self.cards) self.margin() / 2 else 0;
    }
    fn padY(self: Pen) u32 {
        return if (self.cards) self.margin() / 3 else 0;
    }

    /// Biggest clock size (px) that keeps "HH:MM" on one line: IBM Plex Mono glyphs are 0.6em wide,
    /// so 5 glyphs take 3em; keep a little slack.
    fn clockPx(self: Pen, wanted: u32) u32 {
        const avail = self.scr.w - 2 * (self.margin() + self.padX());
        return @min(wanted, avail * 10 / 32);
    }

    /// Total height block() would use for these items.
    fn blockHeight(self: Pen, items: []const Item) u32 {
        const left = self.margin() + self.padX();
        var total: u32 = 0;
        for (items, 0..) |it, i| {
            total += self.measure(it.s, it.px, it.bold, it.center, left, left);
            if (i + 1 < items.len) total += it.px / 3;
        }
        return total + 2 * self.padY();
    }

    /// Draw a group of lines as one block, on a card if a wallpaper is showing.
    /// Returns the y right below the block.
    fn block(self: Pen, top: u32, items: []const Item) u32 {
        const m = self.margin();
        const W = self.scr.w;
        const pad_x = self.padX();
        const pad_y = self.padY();
        const left = m + pad_x;
        const right = m + pad_x;

        var heights: [16]u32 = undefined;
        var total: u32 = 0;
        for (items, 0..) |it, i| {
            if (i == heights.len) break;
            heights[i] = self.measure(it.s, it.px, it.bold, it.center, left, right);
            total += heights[i];
            if (i + 1 < items.len) total += it.px / 3;
        }

        if (self.cards) {
            const ch = total + 2 * pad_y;
            const border: u32 = 3;
            self.rect(m, top, W - 2 * m, ch, self.fgGray());
            self.rect(m + border, top + border, W - 2 * m - 2 * border, ch - 2 * border, self.bgGray());
        }

        var y = top + pad_y;
        for (items, 0..) |it, i| {
            if (i == heights.len) break;
            self.print(it.s, it.px, it.bold, it.center, y, left, right);
            y += heights[i] + it.px / 3;
        }
        return top + total + 2 * pad_y;
    }
};

fn toZ(buf: *[512:0]u8, s: []const u8) [:0]const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

// ---------------------------------------------------------------------------------------
// App state

const App = struct {
    scr: Screen,
    opts: Options,
    cfg: config.Config,
    wp: Wallpapers = .{},

    // The decoded + scaled wallpaper, kept as a framebuffer dump so a minute tick
    // is a memcpy instead of a JPEG decode.
    bg_dump: c.FBInkDump = std.mem.zeroes(c.FBInkDump),
    bg_valid: bool = false,
    bg_idx: usize = 0,
    bg_dark: bool = false,

    gh: ?widgets.GitHub = null,
    gh_checked_at: i64 = -1_000_000,
};

fn wallpaperIndex(app: *const App, now: i64) usize {
    if (app.wp.n == 0) return 0;
    if (app.opts.mode == .saver) return @intCast(@mod(@divFloor(now, 60), @as(i64, @intCast(app.wp.n))));
    if (app.cfg.wallpaper_minutes == 0) return 0;
    const slot = @divFloor(now, @as(i64, app.cfg.wallpaper_minutes) * 60);
    return @intCast(@mod(slot, @as(i64, @intCast(app.wp.n))));
}

/// Clear to the theme background and put the wallpaper (if any) on it. Returns true if a wallpaper is showing.
fn paintBackground(app: *App, pen: Pen, now: i64) bool {
    var k = pen.baseCfg();
    k.is_bgless = false;
    const fd = app.scr.fd;

    if (app.wp.n == 0) {
        _ = c.fbink_cls(fd, &k, null, false);
        return false;
    }

    const idx = wallpaperIndex(app, now);
    if (app.bg_valid and app.bg_idx == idx and app.bg_dark == pen.dark) {
        if (c.fbink_restore(fd, &k, &app.bg_dump) >= 0) return true;
    }

    _ = c.fbink_cls(fd, &k, null, false);
    var pbuf: [300]u8 = undefined;
    const path = app.wp.path(app.cfg.wallpaper_dir, idx, &pbuf) orelse return false;

    var icfg = k;
    icfg.scaled_width = -2; // < -1: fit to screen, keep aspect ratio
    icfg.scaled_height = -2;
    icfg.halign = c.CENTER;
    icfg.valign = c.CENTER;
    icfg.sw_dithering = true; // ordered dithering looks much better than banding on 16-level e-ink
    if (c.fbink_print_image(fd, path.ptr, 0, 0, &icfg) < 0) {
        std.debug.print("zkindle: can't draw wallpaper {s}\n", .{path});
        return false;
    }
    std.debug.print("zkindle: wallpaper {s}\n", .{path});

    if (app.bg_valid) _ = c.fbink_free_dump_data(&app.bg_dump);
    app.bg_valid = c.fbink_dump(fd, &app.bg_dump) >= 0;
    app.bg_idx = idx;
    app.bg_dark = pen.dark;
    return true;
}

// ---------------------------------------------------------------------------------------
// Widgets

var gh_json: [512 * 1024]u8 = undefined;

fn refreshGitHub(app: *App, now: i64) void {
    if (app.cfg.github_user.len == 0) return;
    if (now - app.gh_checked_at < 10 * 60) return; // re-parse at most every 10 minutes
    app.gh_checked_at = now;

    const json = readInto("cache/github.json", &gh_json);
    if (json.len == 0) return;

    var since_t: c.time_t = @intCast(now - 7 * 86400);
    var tm: c.struct_tm = undefined;
    _ = c.gmtime_r(&since_t, &tm);
    var since: [32]u8 = undefined;
    const n = c.strftime(&since, since.len, "%Y-%m-%dT%H:%M:%SZ", &tm);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    app.gh = widgets.summarizeGitHub(arena.allocator(), json, since[0..n]) catch |e| blk: {
        std.debug.print("zkindle: github.json: {s}\n", .{@errorName(e)});
        break :blk null;
    };
}

const WidgetLines = struct {
    bufs: [4][200]u8 = undefined,
    lines: [4][]const u8 = undefined,
    n: usize = 0,

    fn add(self: *WidgetLines, comptime fmt: []const u8, args: anytype) void {
        if (self.n == self.lines.len) return;
        self.lines[self.n] = std.fmt.bufPrint(&self.bufs[self.n], fmt, args) catch return;
        self.n += 1;
    }
};

fn collectWidgets(app: *App, now: i64, tm: *const c.struct_tm, out: *WidgetLines) void {
    // Weather (cache/weather.txt is written by fetch.sh from wttr.in)
    if (app.cfg.city.len > 0) {
        var wbuf: [256]u8 = undefined;
        const w = firstLine(readInto("cache/weather.txt", &wbuf));
        if (w.len > 0 and w.len < 150 and std.mem.indexOf(u8, w, "<") == null) {
            out.add("{s}: {s}", .{ app.cfg.city, w });
        } else {
            out.add("{s}: no weather yet (needs Wi-Fi)", .{app.cfg.city});
        }
    }

    // Countdown
    if (app.cfg.countdown_label.len > 0) {
        if (widgets.parseDate(app.cfg.countdown_date)) |target| {
            const today = widgets.Date{ .y = tm.tm_year + 1900, .m = @intCast(tm.tm_mon + 1), .d = @intCast(tm.tm_mday) };
            var cbuf: [128]u8 = undefined;
            out.add("{s}", .{widgets.formatCountdown(&cbuf, app.cfg.countdown_label, widgets.daysUntil(today, target))});
        }
    }

    // GitHub
    if (app.cfg.github_user.len > 0) {
        refreshGitHub(app, now);
        if (app.gh) |gh| {
            if (gh.last_repo_len > 0) {
                out.add("github: {d} pushes this week, last: {s}", .{ gh.pushes, gh.lastRepo() });
            } else {
                out.add("github: {d} pushes this week", .{gh.pushes});
            }
        }
    }
}

fn quoteOfTheDay(tm: *const c.struct_tm, buf: []u8) ?[]const u8 {
    const text = readInto("quotes.txt", buf);
    const today = widgets.Date{ .y = tm.tm_year + 1900, .m = @intCast(tm.tm_mon + 1), .d = @intCast(tm.tm_mday) };
    const day: usize = @intCast(@max(0, widgets.daysFromCivil(today)));
    return widgets.pickLine(text, day);
}

// ---------------------------------------------------------------------------------------
// Layouts

fn statusLine(app: *const App, buf: []u8) []const u8 {
    const wifi = if (wifiUp()) "on" else "off";
    if (battery()) |b| {
        return std.fmt.bufPrint(buf, "{s}  ·  bat {d}%{s}  ·  wifi {s}", .{
            app.scr.device, b.percent, if (b.charging) "+" else "", wifi,
        }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s}  ·  wifi {s}", .{ app.scr.device, wifi }) catch "";
}

fn todoItems(path: []const u8, text_buf: []u8, out_bufs: [][96]u8, out: [][]const u8) usize {
    const todo = readInto(path, text_buf);
    var lines = std.mem.tokenizeAny(u8, todo, "\r\n");
    var n: usize = 0;
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        out[n] = std.fmt.bufPrint(&out_bufs[n], "- {s}", .{line[0..@min(line.len, 90)]}) catch continue;
        n += 1;
    }
    return n;
}

fn draw(app: *App, flash: bool) void {
    const now = std.time.timestamp();
    var now_t: c.time_t = @intCast(now);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now_t, &tm);

    var pen = Pen{ .scr = &app.scr, .dark = app.cfg.theme == .dark, .cards = false };
    const has_wp = paintBackground(app, pen, now);
    pen.cards = has_wp and app.cfg.cards;

    const H = app.scr.h;
    const gap = H / 60;

    var clock: [16]u8 = undefined;
    const clen = c.strftime(&clock, clock.len, "%H:%M", &tm);
    var date: [64]u8 = undefined;
    const dlen = c.strftime(&date, date.len, "%A %d %B %Y", &tm);
    var sbuf: [128]u8 = undefined;
    const status = statusLine(app, &sbuf);

    switch (app.opts.mode) {
        .saver => {
            // Sleep screen: wallpaper + a small card at the bottom.
            var qbuf: [8192]u8 = undefined;
            const quote = quoteOfTheDay(&tm, &qbuf);
            var since: [48]u8 = undefined;
            const since_s = std.fmt.bufPrint(&since, "sleeping since {s}", .{clock[0..clen]}) catch "sleeping";
            if (has_wp) {
                _ = pen.block(H - H / 5, &.{
                    .{ .s = since_s, .px = H / 40, .bold = true, .center = true },
                    .{ .s = date[0..dlen], .px = H / 52, .center = true },
                });
            } else {
                var y: u32 = H / 4;
                y = pen.block(y, &.{
                    .{ .s = "zkindle", .px = H / 9, .bold = true, .center = true },
                    .{ .s = since_s, .px = H / 36, .center = true },
                });
                if (quote) |q| _ = pen.block(y + gap * 3, &.{.{ .s = q, .px = H / 42, .center = true }});
            }
        },
        else => switch (app.cfg.layout) {
            .minimal => {
                var y: u32 = H / 3;
                y = pen.block(y, &.{
                    .{ .s = clock[0..clen], .px = pen.clockPx(H / 4), .bold = true, .center = true },
                    .{ .s = date[0..dlen], .px = H / 32, .center = true },
                });
            },
            .classic => {
                var y: u32 = H / 30;
                y = pen.block(y, &.{.{ .s = status, .px = H / 48, .center = true }});
                y = pen.block(y + gap, &.{
                    .{ .s = clock[0..clen], .px = pen.clockPx(H / 5), .bold = true, .center = true },
                    .{ .s = date[0..dlen], .px = H / 30, .center = true },
                });

                var tbuf: [4096]u8 = undefined;
                var ibufs: [8][96]u8 = undefined;
                var items: [9]Pen.Item = undefined;
                var lines: [8][]const u8 = undefined;
                const n = todoItems(app.opts.todo_path, &tbuf, &ibufs, &lines);
                items[0] = .{ .s = "today", .px = H / 34, .bold = true };
                for (lines[0..n], 0..) |l, i| items[i + 1] = .{ .s = l, .px = H / 38 };
                if (n == 0) {
                    items[1] = .{ .s = "(edit todo.txt)", .px = H / 38 };
                    _ = pen.block(y + gap * 2, items[0..2]);
                } else {
                    const footer_top = H - H / 16;
                    var count = n + 1;
                    while (count > 1 and y + gap * 2 + pen.blockHeight(items[0..count]) + gap > footer_top) count -= 1;
                    if (count > 1) _ = pen.block(y + gap * 2, items[0..count]);
                }
            },
            .dashboard => {
                var y: u32 = H / 40;
                y = pen.block(y, &.{.{ .s = status, .px = H / 52, .center = true }});
                y = pen.block(y + gap, &.{
                    .{ .s = clock[0..clen], .px = pen.clockPx(H / 6), .bold = true, .center = true },
                    .{ .s = date[0..dlen], .px = H / 34, .center = true },
                });

                var wl = WidgetLines{};
                collectWidgets(app, now, &tm, &wl);
                if (wl.n > 0) {
                    var items: [4]Pen.Item = undefined;
                    for (wl.lines[0..wl.n], 0..) |l, i| items[i] = .{ .s = l, .px = H / 46 };
                    y = pen.block(y + gap, items[0..wl.n]);
                }

                var qbuf: [8192]u8 = undefined;
                if (quoteOfTheDay(&tm, &qbuf)) |q| {
                    y = pen.block(y + gap, &.{.{ .s = q, .px = H / 50, .center = true }});
                }

                var tbuf: [4096]u8 = undefined;
                var ibufs: [5][96]u8 = undefined;
                var lines: [5][]const u8 = undefined;
                const n = todoItems(app.opts.todo_path, &tbuf, &ibufs, &lines);
                if (n > 0) {
                    var items: [6]Pen.Item = undefined;
                    items[0] = .{ .s = "today", .px = H / 42, .bold = true };
                    for (lines[0..n], 0..) |l, i| items[i + 1] = .{ .s = l, .px = H / 46 };
                    // Drop todo items from the end until the card fits above the footer.
                    const footer_top = H - H / 16;
                    var count = n + 1;
                    while (count > 1 and y + gap + pen.blockHeight(items[0..count]) + gap > footer_top) count -= 1;
                    if (count > 1) _ = pen.block(y + gap, items[0..count]);
                }
            },
        },
    }

    if (app.opts.mode != .saver) {
        _ = pen.block(H - H / 16, &.{.{
            .s = "top: layout  ·  middle: refresh  ·  bottom: theme  ·  double-tap: exit",
            .px = H / 72,
            .center = true,
        }});
    }

    // One refresh for the whole frame: one EPDC update instead of N is what makes e-ink feel fast.
    var rcfg = std.mem.zeroes(c.FBInkConfig);
    rcfg.is_flashing = flash;
    rcfg.wfm_mode = if (flash) c.WFM_GC16 else c.WFM_AUTO;
    _ = c.fbink_refresh(app.scr.fd, 0, 0, 0, 0, &rcfg);
}

// ---------------------------------------------------------------------------------------
// Touch input (raw evdev)

// struct input_event on 32-bit ARM: {u32 sec, u32 usec, u16 type, u16 code, s32 value}.
// usize keeps it right on a 64-bit host build too.
const InputEvent = extern struct { sec: usize, usec: usize, type: u16, code: u16, value: i32 };
const InputAbsinfo = extern struct { value: i32, minimum: i32, maximum: i32, fuzz: i32, flat: i32, resolution: i32 };

const EV_KEY = 0x01;
const EV_ABS = 0x03;
const BTN_TOUCH = 0x14a;
const ABS_X = 0x00;
const ABS_Y = 0x01;
const ABS_MT_POSITION_X = 0x35;
const ABS_MT_POSITION_Y = 0x36;
const ABS_MT_TRACKING_ID = 0x39;
const EVIOCGRAB: u32 = 0x40044590; // _IOW('E', 0x90, int)

fn eviocgabs(abs: u32) u32 {
    return 0x80184540 + abs; // _IOR('E', 0x40 + abs, struct input_absinfo)
}

const Range = struct { min: i32, max: i32 };

fn absRange(fd: posix.fd_t, primary: u32, fallback: u32, default_max: u32) Range {
    for ([_]u32{ primary, fallback }) |code| {
        var info = std.mem.zeroes(InputAbsinfo);
        const rc = linux.ioctl(fd, eviocgabs(code), @intFromPtr(&info));
        if (linux.E.init(rc) == .SUCCESS and info.maximum > info.minimum) return .{ .min = info.minimum, .max = info.maximum };
    }
    return .{ .min = 0, .max = @intCast(default_max) };
}

const Tap = struct { x: i32, y: i32 };

const Touch = struct {
    down: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    rx: Range = .{ .min = 0, .max = 1 },
    ry: Range = .{ .min = 0, .max = 1 },

    /// Feed one event; returns the tap position when a finger is lifted.
    fn feed(self: *Touch, ev: InputEvent) ?Tap {
        var pressed: ?bool = null;
        switch (ev.type) {
            EV_KEY => if (ev.code == BTN_TOUCH) {
                pressed = ev.value != 0;
            },
            EV_ABS => switch (ev.code) {
                ABS_MT_TRACKING_ID => pressed = ev.value >= 0,
                ABS_MT_POSITION_X, ABS_X => self.x = ev.value,
                ABS_MT_POSITION_Y, ABS_Y => self.y = ev.value,
                else => {},
            },
            else => {},
        }
        const p = pressed orelse return null;
        defer self.down = p;
        return if (self.down and !p) .{ .x = self.x, .y = self.y } else null;
    }
};

const Zone = enum { top, middle, bottom };

fn zoneOf(app: *const App, t: *const Touch, tap: Tap) Zone {
    var v = tap.y;
    var r = t.ry;
    if (app.scr.touch_swap_axes) {
        v = tap.x;
        r = t.rx;
    }
    var f = @as(f32, @floatFromInt(v - r.min)) / @as(f32, @floatFromInt(@max(1, r.max - r.min)));
    if (app.scr.touch_mirror_y) f = 1.0 - f;
    if (app.cfg.flip_touch) f = 1.0 - f;
    std.debug.print("zkindle: tap x={d} y={d} -> {d:.2}\n", .{ tap.x, tap.y, f });
    if (f < 0.25) return .top;
    if (f > 0.75) return .bottom;
    return .middle;
}

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

    var kcfg = std.mem.zeroes(c.FBInkConfig);
    kcfg.is_quiet = true;
    if (c.fbink_init(fd, &kcfg) < 0) return error.FramebufferInit;

    var st = std.mem.zeroes(c.FBInkState);
    c.fbink_get_state(&kcfg, &st);

    if (c.fbink_add_ot_font(opts.font_regular.ptr, c.FNT_REGULAR) < 0 or
        c.fbink_add_ot_font(opts.font_bold.ptr, c.FNT_BOLD) < 0)
    {
        std.debug.print("zkindle: can't load fonts ({s}, {s})\n", .{ opts.font_regular, opts.font_bold });
        return error.FontLoad;
    }
    defer _ = c.fbink_free_ot_fonts();

    var app = App{
        .scr = .{
            .fd = fd,
            .w = st.view_width,
            .h = st.view_height,
            .device = std.mem.sliceTo(&st.device_name, 0),
            .touch_swap_axes = st.touch_swap_axes,
            .touch_mirror_x = st.touch_mirror_x,
            .touch_mirror_y = st.touch_mirror_y,
        },
        .opts = opts,
        .cfg = loadConfig(&opts),
    };
    defer if (app.bg_valid) {
        _ = c.fbink_free_dump_data(&app.bg_dump);
    };
    app.wp.scan(app.cfg.wallpaper_dir);

    std.debug.print("zkindle: {s} ({s}) {d}x{d} @ {d}bpp, layout {s}, theme {s}, {d} wallpaper(s)\n", .{
        app.scr.device,               std.mem.sliceTo(&st.device_codename, 0), app.scr.w, app.scr.h, st.bpp,
        @tagName(app.cfg.layout), @tagName(app.cfg.theme),                app.wp.n,
    });

    draw(&app, true);
    if (opts.mode != .run) return;

    // ---- find & grab the touchscreen(s)
    var ndev: usize = 0;
    const devs = c.fbink_input_scan(c.INPUT_TOUCHSCREEN, 0, c.NO_RECAP, &ndev);
    defer if (devs != null) std.c.free(devs);

    var pfds_buf: [8]posix.pollfd = undefined;
    var touch = [_]Touch{.{}} ** 8;
    var npfd: usize = 0;
    if (devs != null) {
        for (devs[0..ndev]) |d| {
            if (!d.matched or d.fd < 0 or npfd == pfds_buf.len) continue;
            _ = linux.ioctl(d.fd, EVIOCGRAB, 1); // stop the stock UI from also seeing our taps
            pfds_buf[npfd] = .{ .fd = d.fd, .events = posix.POLL.IN, .revents = 0 };
            touch[npfd].rx = absRange(d.fd, ABS_MT_POSITION_X, ABS_X, app.scr.w);
            touch[npfd].ry = absRange(d.fd, ABS_MT_POSITION_Y, ABS_Y, app.scr.h);
            std.debug.print("zkindle: touch input on {s} ({s}), x {d}..{d}, y {d}..{d}\n", .{
                std.mem.sliceTo(&d.path, 0), std.mem.sliceTo(&d.name, 0),
                touch[npfd].rx.min,         touch[npfd].rx.max,
                touch[npfd].ry.min,         touch[npfd].ry.max,
            });
            npfd += 1;
        }
    }
    defer for (pfds_buf[0..npfd]) |p| posix.close(p.fd);

    // Safety net: without a touchscreen there's no way to exit, so bail out after a minute.
    const no_touch_deadline: ?i64 = if (npfd == 0) nowMs() + 60_000 else null;
    if (npfd == 0) std.debug.print("zkindle: no touchscreen found, exiting in 60s\n", .{});

    var last_tap: i64 = -100_000;
    var pending: ?struct { at: i64, zone: Zone } = null;
    var minutes: u32 = 0;
    const double_tap_ms = 450;

    while (running.load(.monotonic)) {
        const t = nowMs();
        if (no_touch_deadline) |dl| if (t >= dl) break;

        // Sleep until the next minute boundary, or until a pending single-tap action is due.
        var wake = t + (60_000 - @mod(t, 60_000)) + 20;
        if (pending) |p| wake = @min(wake, p.at);
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
                        const tap = touch[i].feed(ev) orelse continue;
                        if (t2 - last_tap < double_tap_ms) {
                            std.debug.print("zkindle: double-tap -> exit\n", .{});
                            running.store(false, .monotonic);
                        } else {
                            last_tap = t2;
                            pending = .{ .at = t2 + double_tap_ms, .zone = zoneOf(&app, &touch[i], tap) };
                        }
                    }
                }
            }
            continue;
        }

        if (pending) |p| if (t2 >= p.at) {
            pending = null;
            switch (p.zone) {
                .top => {
                    app.cfg.layout = app.cfg.layout.next();
                    saveState(app.cfg);
                    std.debug.print("zkindle: layout -> {s}\n", .{@tagName(app.cfg.layout)});
                },
                .bottom => {
                    app.cfg.theme = app.cfg.theme.next();
                    saveState(app.cfg);
                    std.debug.print("zkindle: theme -> {s}\n", .{@tagName(app.cfg.theme)});
                },
                .middle => std.debug.print("zkindle: full refresh\n", .{}),
            }
            draw(&app, true);
            continue;
        };

        // Minute tick: fast partial refresh, with a periodic flash to clear ghosting.
        minutes += 1;
        std.debug.print("zkindle: tick {d}\n", .{minutes});
        draw(&app, minutes % app.cfg.flash_every == 0);
    }

    std.debug.print("zkindle: bye (signal {d})\n", .{last_signal.load(.monotonic)});
}

test {
    _ = config;
    _ = widgets;
}
