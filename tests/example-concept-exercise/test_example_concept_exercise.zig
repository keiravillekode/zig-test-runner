const std = @import("std");
const testing = std.testing;

const lasagna = @import("example_concept_exercise.zig");

// task 1
test "expected minutes in oven" {
    try testing.expectEqual(40, lasagna.expected_minutes_in_oven);
}

// task 2
test "remaining minutes in oven" {
    try testing.expectEqual(15, lasagna.remainingMinutesInOven(25));
}

// task 2
test "remaining minutes in oven, already done" {
    try testing.expectEqual(0, lasagna.remainingMinutesInOven(40));
}

// task 3
test "preparation time for several layers" {
    const layers: u32 = 4;

    try testing.expectEqual(8, lasagna.preparationTimeInMinutes(layers));
}

// Spans tasks 2 and 3, so it is deliberately left unlinked.
test "preparation time and remaining oven time" {
    const preparation = lasagna.preparationTimeInMinutes(2);
    const remaining = lasagna.remainingMinutesInOven(30);
    try testing.expectEqual(14, preparation + remaining);
}
