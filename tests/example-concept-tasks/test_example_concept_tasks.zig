const std = @import("std");
const testing = std.testing;

const lasagna = @import("example_concept_tasks.zig");

// task_id = 1
test "expected minutes in oven" {
    try testing.expectEqual(40, lasagna.expectedMinutesInOven());
}

// task_id = 2
test "remaining minutes in oven" {
    try testing.expectEqual(15, lasagna.remainingMinutesInOven(25));
}

// task_id = 3
test "preparation time for one layer" {
    try testing.expectEqual(2, lasagna.preparationTimeInMinutes(1));
}

// task_id = 3
test "preparation time for four layers" {
    try testing.expectEqual(8, lasagna.preparationTimeInMinutes(4));
}
