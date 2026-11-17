//! zkindle.conf: plain `key = value` lines, `#` starts a comment.
//! Parsing never allocates: string values are slices into the caller's buffer,
//! so the buffer must outlive the Config.

const std = @import("std");

pub const Theme = enum {
    light,
    dark,

    pub fn next(self: Theme) Theme {
        return if (self == .light) .dark else .light;
    }
};

pub const Layout = enum {
    dashboard,
    classic,
    minimal,

    pub fn next(self: Layout) Layout {
        return switch (self) {
            .dashboard => .classic,
            .classic => .minimal,
            .minimal => .dashboard,
        };
    }
};

pub const Config = struct {
    theme: Theme = .light,
    layout: Layout = .dashboard,
    wallpaper_dir: []const u8 = "wallpapers",
    /// Minutes between wallpaper changes; 0 keeps the first one.
    wallpaper_minutes: u32 = 30,
    /// Draw white/black cards behind text when a wallpaper is shown.
    cards: bool = true,
    city: []const u8 = "",
    github_user: []const u8 = "",
    countdown_label: []const u8 = "",
    countdown_date: []const u8 = "",
    /// Full (flashing) refresh every N minute ticks, to clear ghosting.
    flash_every: u32 = 15,
    /// Swap the top/bottom tap zones if the touch panel turns out to be mirrored.
    flip_touch: bool = false,
};

/// Apply every recognised `key = value` line of `text` on top of `cfg`.
/// Unknown keys and malformed values are ignored, so a typo never stops zkindle from starting.
pub fn apply(cfg: *Config, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const no_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        const line = std.mem.trim(u8, no_comment, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        set(cfg, key, val);
    }
}

fn set(cfg: *Config, key: []const u8, val: []const u8) void {
    const eql = std.mem.eql;
    if (eql(u8, key, "theme")) {
        if (std.meta.stringToEnum(Theme, val)) |t| cfg.theme = t;
    } else if (eql(u8, key, "layout")) {
        if (std.meta.stringToEnum(Layout, val)) |l| cfg.layout = l;
    } else if (eql(u8, key, "wallpaper_dir")) {
        cfg.wallpaper_dir = val;
    } else if (eql(u8, key, "wallpaper_minutes")) {
        cfg.wallpaper_minutes = std.fmt.parseInt(u32, val, 10) catch cfg.wallpaper_minutes;
    } else if (eql(u8, key, "cards")) {
        cfg.cards = parseBool(val) orelse cfg.cards;
    } else if (eql(u8, key, "city")) {
        cfg.city = val;
    } else if (eql(u8, key, "github_user")) {
        cfg.github_user = val;
    } else if (eql(u8, key, "countdown")) {
        // countdown = CKA exam | 2027-01-15
        if (std.mem.indexOfScalar(u8, val, '|')) |bar| {
            cfg.countdown_label = std.mem.trim(u8, val[0..bar], " \t");
            cfg.countdown_date = std.mem.trim(u8, val[bar + 1 ..], " \t");
        }
    } else if (eql(u8, key, "flash_every")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return;
        if (n > 0) cfg.flash_every = n;
    } else if (eql(u8, key, "flip_touch")) {
        cfg.flip_touch = parseBool(val) orelse cfg.flip_touch;
    }
}

fn parseBool(v: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes") or std.mem.eql(u8, v, "1")) return true;
    if (std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "no") or std.mem.eql(u8, v, "0")) return false;
    return null;
}

/// The `state` file remembers what you picked with taps (layout + theme) across restarts.
pub fn formatState(buf: []u8, cfg: Config) []const u8 {
    return std.fmt.bufPrint(buf, "layout = {s}\ntheme = {s}\n", .{ @tagName(cfg.layout), @tagName(cfg.theme) }) catch "";
}

test "parse a full config" {
    var cfg = Config{};
    apply(&cfg,
        \\# comment line
        \\theme = dark
        \\layout = minimal   # trailing comment
        \\wallpaper_minutes = 5
        \\cards = no
        \\city = Creteil
        \\github_user = ayoubMah
        \\countdown = CKA exam | 2027-01-15
        \\flash_every = 0
        \\unknown_key = whatever
        \\garbage line
    );
    try std.testing.expectEqual(Theme.dark, cfg.theme);
    try std.testing.expectEqual(Layout.minimal, cfg.layout);
    try std.testing.expectEqual(@as(u32, 5), cfg.wallpaper_minutes);
    try std.testing.expectEqual(false, cfg.cards);
    try std.testing.expectEqualStrings("Creteil", cfg.city);
    try std.testing.expectEqualStrings("ayoubMah", cfg.github_user);
    try std.testing.expectEqualStrings("CKA exam", cfg.countdown_label);
    try std.testing.expectEqualStrings("2027-01-15", cfg.countdown_date);
    try std.testing.expectEqual(@as(u32, 15), cfg.flash_every); // 0 rejected
}

test "bad values keep defaults" {
    var cfg = Config{};
    apply(&cfg, "theme = purple\nlayout=\nwallpaper_minutes = lots\n");
    try std.testing.expectEqual(Theme.light, cfg.theme);
    try std.testing.expectEqual(Layout.dashboard, cfg.layout);
    try std.testing.expectEqual(@as(u32, 30), cfg.wallpaper_minutes);
}

test "state round-trips" {
    var cfg = Config{ .layout = .classic, .theme = .dark };
    var buf: [64]u8 = undefined;
    const s = formatState(&buf, cfg);
    var back = Config{};
    apply(&back, s);
    try std.testing.expectEqual(cfg.layout, back.layout);
    try std.testing.expectEqual(cfg.theme, back.theme);
    cfg.layout = cfg.layout.next();
    try std.testing.expectEqual(Layout.minimal, cfg.layout);
}
