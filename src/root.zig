const std = @import("std");

// this is a simple argument parser
// the DX could be improved, but should be enough for this challenge
pub fn ArgumentParser(comptime specs: []const ArgSpec) type {
    const Config = comptime blk: {
        // increase the size by 1 to add the help field
        var fields: [specs.len + 1]std.builtin.Type.StructField = undefined;

        for (specs, 0..) |spec, i| {
            fields[i] = .{
                .name = convertSliceToSentinelSlice(spec.long),
                .type = if (spec.required or spec.default_value != null or spec.type == bool) spec.type else ?spec.type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(spec.type),
            };
        }

        // add a help field to the end
        fields[fields.len - 1] = .{
            .name = "help",
            .type = bool,
            .default_value_ptr = &false,
            .is_comptime = false,
            .alignment = @alignOf(bool),
        };

        break :blk @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        } });
    };

    // this struct keeps track of which arguments are required, so we can check for missing ones later
    const Required = comptime blk: {
        var fields: [specs.len]std.builtin.Type.StructField = undefined;

        var required_idx: comptime_int = 0;

        for (specs) |spec| {
            if (spec.required) {
                fields[required_idx] = .{
                    .name = convertSliceToSentinelSlice(spec.long),
                    .type = bool,
                    .default_value_ptr = &false,
                    .is_comptime = false,
                    .alignment = 0,
                };
                required_idx += 1;
            }
        }

        break :blk @Type(.{
            .@"struct" = .{
                // use packed to avoid padding as you only have boolean fields
                .layout = .@"packed",
                .fields = fields[0..required_idx],
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_tuple = false,
            },
        });
    };

    return struct {
        const Self = @This();
        pub const help_message = generateHelpMessage(specs);

        pub fn parse(args: []const []const u8) !Config {
            var processed_args = comptime blk: {
                var processed_args: Config = undefined;

                for (specs) |spec| {
                    if (spec.default_value) |val| {
                        @field(processed_args, spec.long) = try stringToTypeVal(spec.type, val);
                    }
                }

                break :blk processed_args;
            };

            var required = Required{};

            // start from the 1st index as 0th is usually the path to the executable
            for (args[1..], 1..) |arg, i| {
                if (std.mem.startsWith(u8, arg, "--")) {
                    if (std.mem.eql(u8, "help", arg[2..])) {
                        @field(processed_args, "help") = true;
                        break;
                    }

                    // as arg_spec is comptime known, we can use inline to unroll the loop
                    inline for (specs) |spec| {
                        if (std.mem.eql(u8, spec.long, arg[2..])) {
                            // bools do not require a value
                            if (spec.type == bool) {
                                @field(processed_args, spec.long) = true;
                                break;
                            }
                            if (i + 1 >= args.len) {
                                std.log.err("Missing value for argument --{s}\n", .{spec.long});
                                return error.MissingValue;
                            }
                            @field(processed_args, spec.long) = stringToTypeVal(spec.type, args[i + 1]) catch return error.InvalidValue;
                            if (spec.required) {
                                @field(required, spec.long) = true;
                            }
                            break;
                        }
                    } else {
                        std.log.err("Unknown argument {s}\n", .{arg});
                        return error.UnknownArgument;
                    }
                } else if (std.mem.startsWith(u8, arg, "-")) {
                    if ('h' == arg[1]) {
                        @field(processed_args, "help") = true;
                        break;
                    }

                    inline for (specs) |spec| {
                        if (spec.short) |short| {
                            if (short == arg[1]) {
                                if (spec.type == bool) {
                                    @field(processed_args, spec.long) = true;
                                    break;
                                }
                                if (i + 1 >= args.len) {
                                    std.log.err("Missing value for argument --{s}\n", .{spec.long});
                                    return error.MissingValue;
                                }
                                @field(processed_args, spec.long) = stringToTypeVal(spec.type, args[i + 1]) catch return error.InvalidValue;
                                if (spec.required) {
                                    @field(required, spec.long) = true;
                                }
                                break;
                            }
                        }
                    } else {
                        std.log.err("Unknown argument {s}\n", .{arg});
                        return error.UnknownArgument;
                    }
                }
            }

            inline for (std.meta.fields(Required)) |field| {
                if (!@field(required, field.name)) {
                    std.log.err("Missing required argument --{s}\n", .{field.name});
                    return error.MissingRequired;
                }
            }

            return processed_args;
        }
    };
}

// all the cli arguments are strings, so we need to convert them to the correct type
fn stringToTypeVal(comptime T: type, str: []const u8) !T {
    switch (T) {
        u8, u16, u32, u64, u128, usize => return try std.fmt.parseInt(T, str, 10),
        i8, i16, i32, i64, i128 => return try std.fmt.parseInt(T, str, 10),
        f32, f64 => return try std.fmt.parseFloat(T, str),
        bool => {
            if (std.mem.eql(u8, str, "true")) return true;
            if (std.mem.eql(u8, str, "false")) return false;
            return error.InvalidValue;
        },
        else => return str,
    }
}

pub fn convertSliceToSentinelSlice(comptime slice: []const u8) [:0]const u8 {
    var buffer: [slice.len + 1]u8 = undefined;
    @memcpy(buffer[0..slice.len], slice);
    buffer[slice.len] = 0;
    return buffer[0..slice.len :0];
}

pub fn generateHelpMessage(comptime specs: []const ArgSpec) []const u8 {
    var result: []const u8 = "Options:\n";

    inline for (specs) |spec| {
        const short_part = if (spec.short) |s| ", -" ++ [1]u8{s} else "";
        const value_part = if (spec.type != void) " <VALUE>" else "";
        const type_part = if (spec.type != void) " (" ++ @typeName(spec.type) ++ ")" else "";
        const default_part = if (spec.default_value) |d| ", default: " ++ d else "";
        const required_part = if (spec.required) " [REQUIRED]" else "";

        const line = "  --" ++ spec.long ++ short_part ++ value_part ++ "    " ++ spec.description ++ type_part ++ default_part ++ required_part ++ "\n";

        result = result ++ line;
    }

    return result;
}

pub const ArgSpec = struct {
    long: []const u8,
    short: ?u8 = null,
    description: []const u8,
    type: type,
    default_value: ?[]const u8 = null,
    required: bool = false,
};

pub const ParseError = error{
    UnknownArgument,
    MissingValue,
    InvalidValue,
    MissingRequired,
};

// for reasons unknown to me, can't seem to use dot syntax to access the fields of a comptime struct in tests, thus the use of @field()
test "parse long arument" {
    const args = [_][]const u8{ "./arg", "--test", "hello" };

    const specs = [_]ArgSpec{
        .{ .long = "test", .type = []const u8, .description = "test", .required = true },
    };

    const config = try ArgumentParser(&specs).parse(&args);

    try std.testing.expectEqualStrings("hello", @field(config, "test"));
}

test "parse short arument" {
    const args = [_][]const u8{ "./arg", "-t", "hello" };

    const specs = [_]ArgSpec{
        ArgSpec{ .long = "test", .short = 't', .type = []const u8, .description = "test", .required = true },
    };

    const config = try ArgumentParser(&specs).parse(&args);

    try std.testing.expectEqualStrings("hello", @field(config, "test"));
}

test "parse arument with default value" {
    const args = [_][]const u8{"./arg"};

    const specs = [_]ArgSpec{
        .{ .long = "test", .type = []const u8, .default_value = "hello", .description = "test" },
    };

    const config = try ArgumentParser(&specs).parse(&args);

    try std.testing.expectEqualStrings("hello", @field(config, "test"));
}

test "parse boolean arugment" {
    const args = [_][]const u8{ "./arg", "--test" };

    const specs = [_]ArgSpec{
        .{ .long = "test", .type = bool, .description = "test" },
    };

    const config = try ArgumentParser(&specs).parse(&args);

    try std.testing.expect(@field(config, "test"));
}

test "parse arugment with invalid value" {
    const args = [_][]const u8{ "./arg", "--test", "invalid" };

    const specs = [_]ArgSpec{
        .{ .long = "test", .type = i32, .description = "test" },
    };

    const config = ArgumentParser(&specs).parse(&args);

    try std.testing.expectError(error.InvalidValue, config);
}

test "parse arugment with missing value" {
    const args = [_][]const u8{ "./arg", "--test" };

    const specs = [_]ArgSpec{
        .{ .long = "test", .type = []const u8, .description = "test", .required = true },
    };

    const config = ArgumentParser(&specs).parse(&args);

    try std.testing.expectError(error.MissingValue, config);
}

test "parse arugment with missing required value" {
    const args = [_][]const u8{"./arg"};

    const specs = [_]ArgSpec{
        .{ .long = "test", .type = []const u8, .description = "test", .required = true },
    };

    const config = ArgumentParser(&specs).parse(&args);

    try std.testing.expectError(error.MissingRequired, config);
}

test "parse unknown argument" {
    const args = [_][]const u8{ "./arg", "--test", "hello", "--unknown" };

    const specs = [_]ArgSpec{
        .{ .long = "test", .type = []const u8, .description = "test", .required = true },
    };

    const config = ArgumentParser(&specs).parse(&args);

    try std.testing.expectError(error.UnknownArgument, config);
}
