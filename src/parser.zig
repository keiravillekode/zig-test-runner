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

pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Parse args
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var exit_code: i32 = 0;
    var output_path: ?[]const u8 = null;
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        const arg = args[ai];
        if (std.mem.eql(u8, arg, "--exit-code")) {
            ai += 1;
            if (ai >= args.len) return err("missing value for --exit-code\n");
            exit_code = std.fmt.parseInt(i32, args[ai], 10) catch
                return err("invalid --exit-code value\n");
        } else if (std.mem.eql(u8, arg, "--output")) {
            ai += 1;
            if (ai >= args.len) return err("missing value for --output\n");
            output_path = args[ai];
        } else {
            return err("unknown argument\n");
        }
    }
    const out_path = output_path orelse return err("--output is required\n");

    // Read stdin
    const stdin = std.fs.File.stdin();
    const input = try stdin.readToEndAlloc(alloc, 1 << 24);
    defer alloc.free(input);

    var tests: std.ArrayList(TestCase) = .{};
    defer {
        for (tests.items) |*t| {
            t.message.deinit(alloc);
            t.output.deinit(alloc);
        }
        tests.deinit(alloc);
    }

    var current: ?TestCase = null;
    defer if (current) |*c| {
        c.message.deinit(alloc);
        c.output.deinit(alloc);
    };

    var seen_test_line: bool = false;

    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (isTestLine(line)) {
            seen_test_line = true;
            if (current) |c| {
                try tests.append(alloc, c);
                current = null;
            }
            const parts = extractNameAndTail(line);
            var tc: TestCase = .{
                .name = parts.name,
                .status = .pass,
                .message = .{},
                .message_set = false,
                .output = .{},
            };
            if (std.mem.endsWith(u8, line, "OK")) {
                tc.status = .pass;
            } else if (tailIsFail(parts.tail)) {
                tc.status = .fail;
                tc.message_set = true;
            } else {
                tc.status = .pending;
                tc.message_set = true;
                try tc.output.appendSlice(alloc, parts.tail);
            }
            current = tc;
        } else if (current != null and current.?.status == .pending) {
            if (isOkLine(line)) {
                current.?.status = .pass;
            } else if (isFailLine(line)) {
                current.?.status = .fail;
                try current.?.message.appendSlice(alloc, line);
            } else {
                try appendWithNewline(&current.?.output, alloc, line);
            }
        } else if (current != null and current.?.status == .fail and !isSummaryLine(line)) {
            try appendWithNewline(&current.?.message, alloc, line);
        } else if (isSummaryLine(line)) {
            if (current) |c| {
                try tests.append(alloc, c);
                current = null;
            }
        }
    }
    if (current) |c| {
        try tests.append(alloc, c);
        current = null;
    }

    // Build output in memory so the final write is atomic-ish (single call).
    var out_buf: ArrayList = .{};
    defer out_buf.deinit(alloc);

    // Compile-error case: non-zero exit, "error:" somewhere in output,
    // and no recognizable test lines.
    if (exit_code != 0 and !seen_test_line and std.mem.indexOf(u8, input, "error:") != null) {
        // Trim trailing newlines from the raw output before embedding.
        var end: usize = input.len;
        while (end > 0 and input[end - 1] == '\n') : (end -= 1) {}
        try writeResultsError(&out_buf, alloc, input[0..end]);
    } else {
        // Normal case: trim/truncate per-test fields then emit.
        for (tests.items) |*t| {
            if (t.message_set) stripTrailingNewlines(&t.message);
            stripTrailingNewlines(&t.output);
            if (t.output.items.len > 0) try truncateOutput(&t.output, alloc);
        }
        const overall: []const u8 = if (exit_code == 0) "pass" else "fail";
        try writeResults(&out_buf, alloc, overall, tests.items);
    }

    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = out_buf.items });
    return 0;
}

fn err(msg: []const u8) !u8 {
    const stderr = std.fs.File.stderr();
    _ = try stderr.write(msg);
    return 1;
}
