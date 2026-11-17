//! Pure helpers behind the dashboard widgets. Nothing in here touches the screen or the
//! network: the network side is fetch.sh, which drops plain files into cache/.

const std = @import("std");

pub const Date = struct { y: i32, m: u8, d: u8 };

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
pub fn daysFromCivil(date: Date) i64 {
    const y: i64 = @as(i64, date.y) - @as(i64, if (date.m <= 2) 1 else 0);
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const m: i64 = date.m;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, date.d) - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// "2027-01-15" -> Date
pub fn parseDate(s: []const u8) ?Date {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, s, " \t\r\n"), '-');
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const m = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    const d = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    if (it.next() != null or m < 1 or m > 12 or d < 1 or d > 31) return null;
    return .{ .y = y, .m = m, .d = d };
}

pub fn daysUntil(today: Date, target: Date) i64 {
    return daysFromCivil(target) - daysFromCivil(today);
}

/// "CKA exam in 59 days" / "CKA exam is tomorrow" / "CKA exam is today" / "CKA exam was 3 days ago"
pub fn formatCountdown(buf: []u8, label: []const u8, days: i64) []const u8 {
    const r = switch (days) {
        0 => std.fmt.bufPrint(buf, "{s} is today", .{label}),
        1 => std.fmt.bufPrint(buf, "{s} is tomorrow", .{label}),
        -1 => std.fmt.bufPrint(buf, "{s} was yesterday", .{label}),
        else => if (days > 0)
            std.fmt.bufPrint(buf, "{s} in {d} days", .{ label, days })
        else
            std.fmt.bufPrint(buf, "{s} was {d} days ago", .{ label, -days }),
    };
    return r catch label;
}

/// The n-th (mod count) usable line of a text file: non-empty and not starting with '#'.
pub fn pickLine(text: []const u8, n: usize) ?[]const u8 {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t");
        if (t.len > 0 and t[0] != '#') count += 1;
    }
    if (count == 0) return null;
    const want = n % count;
    var i: usize = 0;
    it.reset();
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t");
        if (t.len == 0 or t[0] == '#') continue;
        if (i == want) return t;
        i += 1;
    }
    return null;
}

pub const GitHub = struct {
    pushes: u32 = 0,
    events: u32 = 0,
    last_repo_buf: [64]u8 = undefined,
    last_repo_len: usize = 0,

    pub fn lastRepo(self: *const GitHub) []const u8 {
        return self.last_repo_buf[0..self.last_repo_len];
    }
};

/// Summarise GitHub's /users/:user/events/public JSON: activity since `since_iso`
/// ("2026-11-10T16:00:00Z"; ISO-8601 UTC strings compare correctly as plain strings)
/// plus the repo of the most recent event.
pub fn summarizeGitHub(alloc: std.mem.Allocator, json: []const u8, since_iso: []const u8) !GitHub {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    var gh = GitHub{};
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return error.UnexpectedJson, // e.g. {"message": "API rate limit exceeded"}
    };
    for (items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (i == 0) {
            if (obj.get("repo")) |repo| if (repo == .object) if (repo.object.get("name")) |name| if (name == .string) {
                // "ayoubMah/zkindle" -> "zkindle"
                const full = name.string;
                const short = if (std.mem.lastIndexOfScalar(u8, full, '/')) |s| full[s + 1 ..] else full;
                const n = @min(short.len, gh.last_repo_buf.len);
                @memcpy(gh.last_repo_buf[0..n], short[0..n]);
                gh.last_repo_len = n;
            };
        }
        const created = obj.get("created_at") orelse continue;
        if (created != .string or std.mem.order(u8, created.string, since_iso) == .lt) continue;
        gh.events += 1;
        if (obj.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "PushEvent")) {
            gh.pushes += 1;
        };
    }
    return gh;
}

test "days_from_civil known values" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(.{ .y = 1970, .m = 1, .d = 1 }));
    try std.testing.expectEqual(@as(i64, 11016), daysFromCivil(.{ .y = 2000, .m = 2, .d = 29 }));
    try std.testing.expectEqual(@as(i64, 59), daysUntil(.{ .y = 2026, .m = 11, .d = 17 }, .{ .y = 2027, .m = 1, .d = 15 }));
    try std.testing.expectEqual(@as(i64, 1), daysUntil(.{ .y = 2028, .m = 2, .d = 28 }, .{ .y = 2028, .m = 2, .d = 29 }));
}

test "parseDate" {
    const d = parseDate(" 2027-01-15\n").?;
    try std.testing.expectEqual(@as(i32, 2027), d.y);
    try std.testing.expectEqual(@as(u8, 1), d.m);
    try std.testing.expectEqual(@as(u8, 15), d.d);
    try std.testing.expect(parseDate("2027-13-01") == null);
    try std.testing.expect(parseDate("tomorrow") == null);
    try std.testing.expect(parseDate("2027-01-15-01") == null);
}

test "countdown text" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("CKA in 59 days", formatCountdown(&buf, "CKA", 59));
    try std.testing.expectEqualStrings("CKA is today", formatCountdown(&buf, "CKA", 0));
    try std.testing.expectEqualStrings("CKA was 3 days ago", formatCountdown(&buf, "CKA", -3));
}

test "pickLine skips comments and wraps" {
    const t = "# header\n\nfirst\n  second  \n#x\nthird\n";
    try std.testing.expectEqualStrings("first", pickLine(t, 0).?);
    try std.testing.expectEqualStrings("second", pickLine(t, 1).?);
    try std.testing.expectEqualStrings("first", pickLine(t, 3).?);
    try std.testing.expect(pickLine("# only\n", 0) == null);
}

test "github summary" {
    const json =
        \\[{"type":"PushEvent","repo":{"name":"ayoubMah/zkindle"},"created_at":"2026-11-17T10:00:00Z"},
        \\ {"type":"CreateEvent","repo":{"name":"ayoubMah/zkindle"},"created_at":"2026-11-16T21:00:00Z"},
        \\ {"type":"PushEvent","repo":{"name":"ayoubMah/xylem"},"created_at":"2026-11-12T08:00:00Z"},
        \\ {"type":"PushEvent","repo":{"name":"ayoubMah/old"},"created_at":"2026-10-01T08:00:00Z"}]
    ;
    const gh = try summarizeGitHub(std.testing.allocator, json, "2026-11-10T17:00:00Z");
    try std.testing.expectEqual(@as(u32, 2), gh.pushes);
    try std.testing.expectEqual(@as(u32, 3), gh.events);
    try std.testing.expectEqualStrings("zkindle", gh.lastRepo());
    try std.testing.expectError(error.UnexpectedJson, summarizeGitHub(std.testing.allocator, "{\"message\":\"rate limited\"}", "x"));
}
