const std = @import("std");

pub fn greet() ![]const u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll("debug: computed bad greeting\n");
    try w.interface.flush();
    return "Goodbye";
}
