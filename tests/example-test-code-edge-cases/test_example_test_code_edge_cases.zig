const std = @import("std");
const testing = std.testing;

const edge = @import("example_test_code_edge_cases.zig");

// task 1
test "brace inside a string literal" {
    try testing.expectEqualStrings("}", edge.brace());
}

// task 1
test "nested blocks keep their relative indentation" {
    const cfg = .{ .a = 1, .b = .{ .c = 2 } };
    if (cfg.a == 1) {
        try testing.expectEqual(3, edge.nested());
    }
}

// task 2
test "empty body" {}

// task 2
test "multiline string literal in the body" {
    const text =
        \\line one
        \\line two
    ;
    try testing.expect(text.len > 0);
}
