const std = @import("std");
const argparse = @import("argparse");

const Args = [_]argparse.ArgSpec{.{ .long = "input", .short = 'i', .type = []const u8, .description = "Input file", .required = true }};

// example of how to use the argparse library
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);

    const argparser = argparse.ArgumentParser(&Args);
    const config = try argparser.parse(arguments);

    std.debug.print("input: {s}\n", .{config.input});
}
