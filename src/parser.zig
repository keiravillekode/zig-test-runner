// Exercism test-output parser for the Zig track.
//
// Reads raw `zig test` stdout+stderr from stdin and emits a v2 `results.json`
// matching Exercism's test-runner interface:
// https://exercism.org/docs/building/tooling/test-runners/interface
//
// Usage:
//   exercism-parser --exit-code <N> --output <path/to/results.json>

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList(u8);
const Io = std.Io;

const TRUNCATE_AT: usize = 500;
const TRUNCATED_SUFFIX: []const u8 = " [output truncated]";

const Status = enum {
    pass,
    fail,
    pending,

    fn name(self: Status) []const u8 {
        return switch (self) {
            .pass => "pass",
            .fail => "fail",
            .pending => "pending",
        };
    }
};

const TestCase = struct {
    name: []const u8, // slice into stdin buffer
    status: Status,
    message: ArrayList,
    // The `message` field appears in the output whenever it was populated at
    // any point (even if later trimmed empty). Pass-via-OK tests never set it.
    message_set: bool,
    output: ArrayList,
};

fn isTestLine(line: []const u8) bool {
    // ^[0-9]+/[0-9]+ .*\.test\..*\.\.\.
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == 0) return false;
    if (i >= line.len or line[i] != '/') return false;
    i += 1;
    const denom_start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == denom_start) return false;
    if (i >= line.len or line[i] != ' ') return false;
    const rest = line[i + 1 ..];
    const marker = std.mem.indexOf(u8, rest, ".test.") orelse return false;
    return std.mem.indexOf(u8, rest[marker + 6 ..], "...") != null;
}

const NameTail = struct { name: []const u8, tail: []const u8 };

// Assumes isTestLine(line) == true. The name is the slice between the first
// `.test.` and the LAST `...` on the line (greedy match).
fn extractNameAndTail(line: []const u8) NameTail {
    const marker = std.mem.indexOf(u8, line, ".test.").?;
    const after = line[marker + 6 ..];
    const last_dots = std.mem.lastIndexOf(u8, after, "...").?;
    return .{
        .name = after[0..last_dots],
        .tail = after[last_dots + 3 ..],
    };
}

// Called on a test line's tail (substring after the last `...`) to decide
// whether it's an immediate FAIL on the same line.
fn tailIsFail(tail: []const u8) bool {
    return std.mem.startsWith(u8, tail, "FAIL") or
        std.mem.startsWith(u8, tail, "expected ");
}

fn isOkLine(line: []const u8) bool {
    return std.mem.endsWith(u8, line, "OK");
}

fn isFailLine(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "FAIL")) return true;
    if (std.mem.indexOf(u8, line, "...FAIL") != null) return true;
    if (std.mem.indexOf(u8, line, "...expected ") != null) return true;
    return false;
}

fn isSummaryLine(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "All ")) return true;
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == 0) return false;
    return std.mem.startsWith(u8, line[i..], " passed;");
}

fn appendWithNewline(buf: *ArrayList, alloc: Allocator, line: []const u8) !void {
    if (buf.items.len > 0) try buf.append(alloc, '\n');
    try buf.appendSlice(alloc, line);
}

fn stripTrailingNewlines(buf: *ArrayList) void {
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
        _ = buf.pop();
    }
}

fn truncateOutput(buf: *ArrayList, alloc: Allocator) !void {
    if (buf.items.len <= TRUNCATE_AT) return;
    buf.items.len = 481;
    try buf.appendSlice(alloc, TRUNCATED_SUFFIX);
}

fn writeJsonString(out: *ArrayList, alloc: Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '"' => try out.appendSlice(alloc, "\\\""),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var buf: [8]u8 = undefined;
                const slice = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{@as(u16, c)});
                try out.appendSlice(alloc, slice);
            },
            else => try out.append(alloc, c),
        }
    }
    try out.append(alloc, '"');
}

fn writeResultsError(out: *ArrayList, alloc: Allocator, message: []const u8) !void {
    try out.appendSlice(alloc, "{\n  \"version\": 2,\n  \"status\": \"error\",\n  \"message\": ");
    try writeJsonString(out, alloc, message);
    try out.appendSlice(alloc, "\n}\n");
}

fn writeResults(out: *ArrayList, alloc: Allocator, overall: []const u8, tests: []const TestCase) !void {
    try out.appendSlice(alloc, "{\n  \"version\": 2,\n  \"status\": ");
    try writeJsonString(out, alloc, overall);
    try out.appendSlice(alloc, ",\n  \"tests\": ");
    if (tests.len == 0) {
        try out.appendSlice(alloc, "[]\n}\n");
        return;
    }
    try out.appendSlice(alloc, "[\n");
    for (tests, 0..) |t, i| {
        try out.appendSlice(alloc, "    {\n      \"name\": ");
        try writeJsonString(out, alloc, t.name);
        try out.appendSlice(alloc, ",\n      \"status\": ");
        try writeJsonString(out, alloc, t.status.name());
        if (t.message_set) {
            try out.appendSlice(alloc, ",\n      \"message\": ");
            try writeJsonString(out, alloc, t.message.items);
        }
        if (t.output.items.len > 0) {
            try out.appendSlice(alloc, ",\n      \"output\": ");
            try writeJsonString(out, alloc, t.output.items);
        }
        try out.appendSlice(alloc, "\n    }");
        if (i + 1 < tests.len) {
            try out.appendSlice(alloc, ",\n");
        } else {
            try out.append(alloc, '\n');
        }
    }
    try out.appendSlice(alloc, "  ]\n}\n");
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var exit_code: i32 = 0;
    var output_path: ?[]const u8 = null;
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        const arg = args[ai];
        if (std.mem.eql(u8, arg, "--exit-code")) {
            ai += 1;
            if (ai >= args.len) return errMsg(io, "missing value for --exit-code\n");
            exit_code = std.fmt.parseInt(i32, args[ai], 10) catch
                return errMsg(io, "invalid --exit-code value\n");
        } else if (std.mem.eql(u8, arg, "--output")) {
            ai += 1;
            if (ai >= args.len) return errMsg(io, "missing value for --output\n");
            output_path = args[ai];
        } else {
            return errMsg(io, "unknown argument\n");
        }
    }
    const out_path = output_path orelse return errMsg(io, "--output is required\n");

    // Read stdin into a heap buffer.
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const input = try stdin_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(input);

    var tests: std.ArrayList(TestCase) = .empty;
    defer {
        for (tests.items) |*t| {
            t.message.deinit(gpa);
            t.output.deinit(gpa);
        }
        tests.deinit(gpa);
    }

    var current: ?TestCase = null;
    defer if (current) |*c| {
        c.message.deinit(gpa);
        c.output.deinit(gpa);
    };

    var seen_test_line: bool = false;

    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (isTestLine(line)) {
            seen_test_line = true;
            if (current) |c| {
                try tests.append(gpa, c);
                current = null;
            }
            const parts = extractNameAndTail(line);
            var tc: TestCase = .{
                .name = parts.name,
                .status = .pass,
                .message = .empty,
                .message_set = false,
                .output = .empty,
            };
            if (std.mem.endsWith(u8, line, "OK")) {
                tc.status = .pass;
            } else if (tailIsFail(parts.tail)) {
                tc.status = .fail;
                tc.message_set = true;
            } else {
                tc.status = .pending;
                tc.message_set = true;
                try tc.output.appendSlice(gpa, parts.tail);
            }
            current = tc;
        } else if (current != null and current.?.status == .pending) {
            if (isOkLine(line)) {
                current.?.status = .pass;
            } else if (isFailLine(line)) {
                current.?.status = .fail;
                try current.?.message.appendSlice(gpa, line);
            } else {
                try appendWithNewline(&current.?.output, gpa, line);
            }
        } else if (current != null and current.?.status == .fail and !isSummaryLine(line)) {
            try appendWithNewline(&current.?.message, gpa, line);
        } else if (isSummaryLine(line)) {
            if (current) |c| {
                try tests.append(gpa, c);
                current = null;
            }
        }
    }
    if (current) |c| {
        try tests.append(gpa, c);
        current = null;
    }

    // Build output in memory so the final write is atomic-ish (single call).
    var out_buf: ArrayList = .empty;
    defer out_buf.deinit(gpa);

    if (exit_code != 0 and !seen_test_line and std.mem.indexOf(u8, input, "error:") != null) {
        // Trim trailing newlines from the raw output before embedding.
        var end: usize = input.len;
        while (end > 0 and input[end - 1] == '\n') : (end -= 1) {}
        try writeResultsError(&out_buf, gpa, input[0..end]);
    } else {
        for (tests.items) |*t| {
            if (t.message_set) stripTrailingNewlines(&t.message);
            stripTrailingNewlines(&t.output);
            if (t.output.items.len > 0) try truncateOutput(&t.output, gpa);
        }
        const overall: []const u8 = if (exit_code == 0) "pass" else "fail";
        try writeResults(&out_buf, gpa, overall, tests.items);
    }

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = out_buf.items,
        .flags = .{},
    });
    return 0;
}

fn errMsg(io: Io, msg: []const u8) !u8 {
    try Io.File.stderr().writeStreamingAll(io, msg);
    return 1;
}
