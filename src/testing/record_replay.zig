//! Record/replay utility for TUI sessions.
//!
//! Captures a sequence of timestamped key events to disk so demos and bug
//! reports become reproducible. The file format is a small line-oriented
//! text format:
//!
//!     ms=0 key=char ch=104
//!     ms=40 key=char ch=105
//!     ms=120 key=enter
//!     ms=200 mod=ctrl+key=char ch=99
//!
//! Each line is: `ms=<elapsed-ms> [mod=<mods>+]key=<name> [ch=<codepoint>] [str=<escaped>]`.
//!
//! `Recorder` appends events to an in-memory buffer which can be written to a
//! file at the end of a session. `Player` reads a file and exposes an
//! iterator of `Event` values, optionally gated on wall-clock time so the
//! replay feels natural.

const std = @import("std");
const keys = @import("../input/keys.zig");

pub const Event = struct {
    elapsed_ms: u64,
    event: keys.KeyEvent,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    events: std.array_list.Managed(Event),
    start_ns: i128,

    pub fn init(allocator: std.mem.Allocator) Recorder {
        return .{
            .allocator = allocator,
            .events = std.array_list.Managed(Event).init(allocator),
            .start_ns = std.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.events.deinit();
    }

    pub fn reset(self: *Recorder) void {
        self.events.clearRetainingCapacity();
        self.start_ns = std.time.nanoTimestamp();
    }

    /// Record an event that occurred at the current wall-clock time.
    pub fn record(self: *Recorder, event: keys.KeyEvent) !void {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.start_ns;
        const ms: u64 = if (elapsed_ns < 0) 0 else @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
        try self.events.append(.{ .elapsed_ms = ms, .event = event });
    }

    /// Record an event at an explicit elapsed millisecond offset from start.
    pub fn recordAt(self: *Recorder, elapsed_ms: u64, event: keys.KeyEvent) !void {
        try self.events.append(.{ .elapsed_ms = elapsed_ms, .event = event });
    }

    /// Serialize the recording to a writer.
    pub fn write(self: *const Recorder, writer: std.io.AnyWriter) !void {
        for (self.events.items) |e| {
            try writeEvent(writer, e);
        }
    }

    /// Serialize the recording to a file at `path`.
    pub fn writeToFile(self: *const Recorder, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var buf: [4096]u8 = undefined;
        var fw = file.writer(&buf);
        try self.write(fw.interface.any());
        try fw.interface.flush();
    }
};

pub const Player = struct {
    allocator: std.mem.Allocator,
    events: []Event,
    cursor: usize,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Player {
        const contents = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(contents);
        return parse(allocator, contents);
    }

    pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !Player {
        var list = std.array_list.Managed(Event).init(allocator);
        errdefer {
            for (list.items) |e| freeEvent(allocator, e.event);
            list.deinit();
        }

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const event = try parseLine(allocator, trimmed);
            try list.append(event);
        }

        return .{
            .allocator = allocator,
            .events = try list.toOwnedSlice(),
            .cursor = 0,
        };
    }

    pub fn deinit(self: *Player) void {
        for (self.events) |e| freeEvent(self.allocator, e.event);
        self.allocator.free(self.events);
    }

    /// Return the next event, or null if exhausted.
    pub fn next(self: *Player) ?Event {
        if (self.cursor >= self.events.len) return null;
        const e = self.events[self.cursor];
        self.cursor += 1;
        return e;
    }

    pub fn reset(self: *Player) void {
        self.cursor = 0;
    }

    pub fn len(self: *const Player) usize {
        return self.events.len;
    }
};

fn freeEvent(allocator: std.mem.Allocator, event: keys.KeyEvent) void {
    switch (event.key) {
        .paste => |s| allocator.free(s),
        .unknown => |s| allocator.free(s),
        else => {},
    }
}

fn writeEvent(writer: std.io.AnyWriter, e: Event) !void {
    try writer.print("ms={d}", .{e.elapsed_ms});

    const m = e.event.modifiers;
    if (m.any()) {
        try writer.writeAll(" mod=");
        var first = true;
        if (m.ctrl) {
            try writer.writeAll("ctrl");
            first = false;
        }
        if (m.alt) {
            if (!first) try writer.writeByte('+');
            try writer.writeAll("alt");
            first = false;
        }
        if (m.shift) {
            if (!first) try writer.writeByte('+');
            try writer.writeAll("shift");
            first = false;
        }
        if (m.super) {
            if (!first) try writer.writeByte('+');
            try writer.writeAll("super");
        }
    }

    try writer.print(" key={s}", .{e.event.key.name()});

    switch (e.event.key) {
        .char => |c| try writer.print(" ch={d}", .{c}),
        .paste => |s| {
            try writer.writeAll(" str=");
            try writeEscaped(writer, s);
        },
        .unknown => |s| {
            try writer.writeAll(" str=");
            try writeEscaped(writer, s);
        },
        else => {},
    }
    try writer.writeByte('\n');
}

fn writeEscaped(writer: std.io.AnyWriter, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\\' => try writer.writeAll("\\\\"),
            ' ' => try writer.writeAll("\\s"),
            else => if (c < 0x20) {
                try writer.print("\\x{x:0>2}", .{c});
            } else {
                try writer.writeByte(c);
            },
        }
    }
}

fn unescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, s.len);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\') {
            try out.append(s[i]);
            continue;
        }
        if (i + 1 >= s.len) return error.InvalidEscape;
        i += 1;
        switch (s[i]) {
            'n' => try out.append('\n'),
            'r' => try out.append('\r'),
            't' => try out.append('\t'),
            '\\' => try out.append('\\'),
            's' => try out.append(' '),
            'x' => {
                if (i + 2 >= s.len) return error.InvalidEscape;
                const hex = s[i + 1 .. i + 3];
                const byte = try std.fmt.parseInt(u8, hex, 16);
                try out.append(byte);
                i += 2;
            },
            else => return error.InvalidEscape,
        }
    }

    return out.toOwnedSlice();
}

fn parseSimpleKey(name: []const u8) ?keys.Key {
    const table = [_]struct { name: []const u8, key: keys.Key }{
        .{ .name = "up", .key = .up },
        .{ .name = "down", .key = .down },
        .{ .name = "left", .key = .left },
        .{ .name = "right", .key = .right },
        .{ .name = "home", .key = .home },
        .{ .name = "end", .key = .end },
        .{ .name = "page_up", .key = .page_up },
        .{ .name = "page_down", .key = .page_down },
        .{ .name = "insert", .key = .insert },
        .{ .name = "delete", .key = .delete },
        .{ .name = "backspace", .key = .backspace },
        .{ .name = "enter", .key = .enter },
        .{ .name = "tab", .key = .tab },
        .{ .name = "escape", .key = .escape },
        .{ .name = "space", .key = .space },
        .{ .name = "null", .key = .null_key },
        .{ .name = "f1", .key = .f1 },
        .{ .name = "f2", .key = .f2 },
        .{ .name = "f3", .key = .f3 },
        .{ .name = "f4", .key = .f4 },
        .{ .name = "f5", .key = .f5 },
        .{ .name = "f6", .key = .f6 },
        .{ .name = "f7", .key = .f7 },
        .{ .name = "f8", .key = .f8 },
        .{ .name = "f9", .key = .f9 },
        .{ .name = "f10", .key = .f10 },
        .{ .name = "f11", .key = .f11 },
        .{ .name = "f12", .key = .f12 },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.key;
    }
    return null;
}

fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Event {
    var ms: u64 = 0;
    var mods: keys.Modifiers = .{};
    var key_name: []const u8 = "";
    var codepoint: ?u21 = null;
    var str_value: ?[]const u8 = null;

    var tokens = std.mem.splitScalar(u8, line, ' ');
    while (tokens.next()) |tok| {
        if (tok.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.InvalidLine;
        const name = tok[0..eq];
        const value = tok[eq + 1 ..];

        if (std.mem.eql(u8, name, "ms")) {
            ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, name, "mod")) {
            var parts = std.mem.splitScalar(u8, value, '+');
            while (parts.next()) |p| {
                if (std.mem.eql(u8, p, "ctrl")) {
                    mods.ctrl = true;
                } else if (std.mem.eql(u8, p, "alt")) {
                    mods.alt = true;
                } else if (std.mem.eql(u8, p, "shift")) {
                    mods.shift = true;
                } else if (std.mem.eql(u8, p, "super")) {
                    mods.super = true;
                }
            }
        } else if (std.mem.eql(u8, name, "key")) {
            key_name = value;
        } else if (std.mem.eql(u8, name, "ch")) {
            codepoint = @intCast(try std.fmt.parseInt(u32, value, 10));
        } else if (std.mem.eql(u8, name, "str")) {
            str_value = value;
        }
    }

    const key: keys.Key = key_blk: {
        if (std.mem.eql(u8, key_name, "char")) {
            break :key_blk .{ .char = codepoint orelse return error.InvalidLine };
        }
        if (std.mem.eql(u8, key_name, "paste")) {
            const raw = str_value orelse return error.InvalidLine;
            break :key_blk .{ .paste = try unescape(allocator, raw) };
        }
        if (std.mem.eql(u8, key_name, "unknown")) {
            const raw = str_value orelse return error.InvalidLine;
            break :key_blk .{ .unknown = try unescape(allocator, raw) };
        }
        break :key_blk parseSimpleKey(key_name) orelse return error.UnknownKey;
    };

    return .{ .elapsed_ms = ms, .event = .{ .key = key, .modifiers = mods } };
}

test "record and replay roundtrip" {
    const allocator = std.testing.allocator;
    var rec = Recorder.init(allocator);
    defer rec.deinit();

    try rec.recordAt(0, .{ .key = .{ .char = 'h' } });
    try rec.recordAt(40, .{ .key = .{ .char = 'i' } });
    try rec.recordAt(120, .{ .key = .enter });
    try rec.recordAt(200, .{ .key = .{ .char = 'c' }, .modifiers = .{ .ctrl = true } });

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try rec.write(buf.writer().any());

    var player = try Player.parse(allocator, buf.items);
    defer player.deinit();

    const e1 = player.next().?;
    try std.testing.expectEqual(@as(u64, 0), e1.elapsed_ms);
    try std.testing.expectEqual(@as(u21, 'h'), e1.event.key.char);

    const e3 = player.next().?; // skip second
    _ = e3;
    const enter_event = player.next().?;
    try std.testing.expect(enter_event.event.key == .enter);
    try std.testing.expectEqual(@as(u64, 120), enter_event.elapsed_ms);

    const ctrl_c = player.next().?;
    try std.testing.expect(ctrl_c.event.modifiers.ctrl);
}

test "parse ignores blank lines and comments" {
    const allocator = std.testing.allocator;
    const input =
        \\# demo
        \\
        \\ms=0 key=enter
        \\
    ;
    var player = try Player.parse(allocator, input);
    defer player.deinit();
    try std.testing.expectEqual(@as(usize, 1), player.len());
}
