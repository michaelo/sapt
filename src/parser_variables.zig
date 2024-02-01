const std = @import("std");
const testing = std.testing;
const debug = std.debug.print;
const KvStore = @import("kvstore.zig").KvStore;
const utils = @import("utils.zig");

pub const BracketPair = struct {
    start: usize,
    end: usize,
    depth: usize, // If nested, how deep
    resolved: bool = false,
};

/// Parsers buffer for {{something}}-entries, and provides an array of BracketPair-entries to use for further processing. It doesn't
/// discriminate based on if the contents are valid variable names or functions etc, this must be handled later.
pub fn findAllVariables(comptime BufferSize: usize, comptime MaxNumVariables: usize, buffer: *std.BoundedArray(u8, BufferSize)) !std.BoundedArray(BracketPair, MaxNumVariables) {
    var opens: std.BoundedArray(usize, MaxNumVariables) = std.BoundedArray(usize, MaxNumVariables).init(0) catch unreachable;
    var pairs: std.BoundedArray(BracketPair, MaxNumVariables) = std.BoundedArray(BracketPair, MaxNumVariables).init(0) catch unreachable;
    var skip_next = false;

    for (buffer.slice()[0 .. buffer.slice().len - 1], 0..) |char, i| {
        if (skip_next) {
            skip_next = false;
            continue;
        }

        switch (char) {
            '{' => {
                if (buffer.slice()[i + 1] == '{') {
                    try opens.append(i);
                    skip_next = true;
                }
            },
            '}' => {
                if (buffer.slice()[i + 1] == '}') {
                    skip_next = true;
                    // pop, if any.
                    if (opens.slice().len > 0) {
                        try pairs.append(BracketPair{ .start = opens.pop(), .end = i + 1, .depth = opens.slice().len });
                    } else {
                        // TODO: convert to line and col
                        // TODO: Print surrounding slice?
                        // Att! Not an error. E.g. for json-payloads...
                        debug("WARNING: Found close-brackets at idx={d} with none open\n", .{i});
                    }
                }
            },
            else => {},
        }
    }

    if (opens.slice().len > 0) {
        for (opens.slice()) |idx| debug("WARNING: Brackets remaining open: idx={d}\n", .{idx});
        // TODO: Print surrounding slice?
    }

    return pairs;
}

/// Buffer must be large enough to contain the expanded variant.
/// TODO: Test performance with fixed sizes. Possibly redesign the outer to utilize a common scrap buffer
pub fn expandVariables(comptime BufferSize: usize, comptime MaxNumVariables: usize, buffer: *std.BoundedArray(u8, BufferSize), pairs: *std.BoundedArray(BracketPair, MaxNumVariables), variables: *KvStore) error{ BufferTooSmall, Overflow }!void {
    // Algorithm:
    // * prereq: pairs are sorted by depth, desc
    // * pick entry from pairs until empty
    // * extract key
    // * get value for key
    // * calculate length-diff as "end_delta"
    // * substitute slice in buffer
    // * loop through all remaining pairs and any .start or .end that's > prev.end + end_delta with + end_delta
    var end_delta: i64 = 0;
    for (pairs.slice()) |*pair| {
        if (pair.resolved) continue;
        var pair_len = pair.end - pair.start + 1;
        var key = buffer.slice()[pair.start + 2 .. pair.end - 1];

        // check if key is a variable (not function)
        if (!(std.mem.indexOf(u8, key, "(") != null and std.mem.indexOf(u8, key, ")") != null)) {
            if (variables.get(key)) |value| {
                var value_len = value.len;
                end_delta = @as(i32, @intCast(value_len)) - (@as(i32, @intCast(key.len)) + 4); // 4 == {{}}
                buffer.replaceRange(pair.start, pair_len, value) catch {
                    return error.BufferTooSmall;
                };
                pair.resolved = true;

                for (pairs.slice()[0..]) |*pair2| {
                    if (pair2.resolved) continue; // Since we no longer go exclusively by depth (we run this function multiple times with different sets), we have to check from start and filter out resolved instead
                    if (pair2.start > @as(i64, @intCast(pair.start + 1))) pair2.start = try utils.addUnsignedSigned(u64, i64, pair2.start, end_delta);
                    if (pair2.end > @as(i64, @intCast(pair.start + 1))) pair2.end = try utils.addUnsignedSigned(u64, i64, pair2.end, end_delta);
                }
            } else {
                // TODO: Make verbose-dependent?
                // debug("WARNING: Could not resolve variable: '{s}'\n", .{key});
                // result = error.NoSuchVariableFound;
            }
        }
    }
}

const FunctionEntryFuncPtr = *const fn (std.mem.Allocator, []const u8, *std.BoundedArray(u8, 1024)) anyerror!void;

const FunctionEntry = struct {
    name: []const u8,
    function: FunctionEntryFuncPtr,
    fn create(name: []const u8, function: FunctionEntryFuncPtr) FunctionEntry {
        return .{ .name = name, .function = function };
    }
};

fn funcMyfunc(_: std.mem.Allocator, value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    try out_buf.insertSlice(0, value);
}

fn funcBase64enc(_: std.mem.Allocator, value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    var buffer: [1024]u8 = undefined;
    try out_buf.insertSlice(0, std.base64.standard.Encoder.encode(&buffer, value));
}

test "funcBase64enc" {
    var input = "abcde12345:";
    var expected = "YWJjZGUxMjM0NTo=";

    var output = try std.BoundedArray(u8, 1024).init(0);
    try funcBase64enc(std.testing.allocator, input, &output);
    try testing.expectEqualStrings(expected, output.constSlice());
}

fn funcEnv(allocator: std.mem.Allocator, value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    const env_value = try std.process.getEnvVarOwned(allocator, value);
    defer allocator.free(env_value);
    try out_buf.insertSlice(0, utils.sliceUpTo(u8, env_value, 0, 1024));
    if (env_value.len > out_buf.capacity()) {
        return error.Overflow;
    }
}

test "funcEnv" {
    var input = "PATH";

    var output = try std.BoundedArray(u8, 1024).init(0);
    funcEnv(std.testing.allocator, input, &output) catch |e| switch (e) {
        error.Overflow => {},
        else => return e,
    };
    try testing.expect(output.slice().len > 0);
}

// fn funcBase64dec() !void {

// }

// fn funcUrlencode() !void {

// }

pub fn getFunction(functions: []const FunctionEntry, name: []const u8) error{NoSuchFunction}!FunctionEntryFuncPtr {
    // Att: Inefficient. If data set increases, improve (PERFORMANCE)
    for (functions) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.function;
        }
    }

    return error.NoSuchFunction;
}

test "getFunction" {
    const TestFunctions = struct {
        fn funcWoop(_: std.mem.Allocator, value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
            _ = value;
            try out_buf.insertSlice(0, "woop");
        }

        fn funcBlank(_: std.mem.Allocator, value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
            _ = value;
            try out_buf.insertSlice(0, "");
        }
    };

    const functions = [_]FunctionEntry{
        FunctionEntry.create("woopout", TestFunctions.funcWoop),
        FunctionEntry.create("blank", TestFunctions.funcBlank),
    };

    const functions_slice = functions[0..];

    var buf = std.BoundedArray(u8, 1024).init(0) catch unreachable;
    try (try getFunction(functions_slice, "woopout"))(std.testing.allocator, "doesntmatter", &buf);
    try testing.expectEqualStrings("woop", buf.slice());

    try buf.resize(0);
    try (try getFunction(functions_slice, "blank"))(std.testing.allocator, "doesntmatter", &buf);
    try testing.expectEqualStrings("", buf.slice());

    try buf.resize(0);
    try testing.expectError(error.NoSuchFunction, getFunction(functions_slice, "nosuchfunction"));

    try (try getFunction(global_functions[0..], "myfunc"))(std.testing.allocator, "mydata", &buf);
    try testing.expectEqualStrings("mydata", buf.slice());
}

const global_functions = [_]FunctionEntry{
    FunctionEntry.create("myfunc", funcMyfunc),
    FunctionEntry.create("base64enc", funcBase64enc),
    FunctionEntry.create("env", funcEnv),
};

/// Convenience-function looking up functions from the global default-list of functions
pub fn getGlobalFunction(name: []const u8) !FunctionEntryFuncPtr {
    return getFunction(global_functions[0..], name);
}

///
pub fn expandFunctions(comptime BufferSize: usize, comptime MaxNumVariables: usize, buffer: *std.BoundedArray(u8, BufferSize), pairs: *std.BoundedArray(BracketPair, MaxNumVariables)) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var end_delta: i64 = 0;
    for (pairs.slice(), 0..) |*pair, i| {
        if (pair.resolved) continue;
        var pair_len = pair.end - pair.start + 1;
        var key = buffer.slice()[pair.start + 2 .. pair.end - 1];

        // check if key is a function, otherwise ignore
        if (std.mem.indexOf(u8, key, "(") != null and std.mem.indexOf(u8, key, ")") != null) {
            // Parse function name, extract "parameter", lookup and call proper function
            var func_key = key[0..std.mem.indexOf(u8, key, "(").?];
            var func_arg = key[std.mem.indexOf(u8, key, "(").? + 1 .. std.mem.indexOf(u8, key, ")").?];
            var function = try getGlobalFunction(func_key);
            var func_buf = utils.initBoundedArray(u8, 1024);
            try function(allocator, func_arg, &func_buf);

            buffer.replaceRange(pair.start, pair_len, func_buf.slice()) catch {
                // .Overflow
                return error.BufferTooSmall;
            };
            pair.resolved = true;
            end_delta = @as(i32, @intCast(func_buf.slice().len)) - (@as(i32, @intCast(key.len)) + 4); // 4 == {{}}

            for (pairs.slice()[i + 1 ..]) |*pair2| {
                if (pair2.start > @as(i64, @intCast(pair.start + 1))) pair2.start = try utils.addUnsignedSigned(u64, i64, pair2.start, end_delta);
                if (pair2.end > @as(i64, @intCast(pair.start + 1))) pair2.end = try utils.addUnsignedSigned(u64, i64, pair2.end, end_delta);
            }
        }
    }
}

test "bracketparsing - variables and functions" {
    const MAX_VARIABLES = 64;
    var str = try std.BoundedArray(u8, 1024).fromSlice(
        \\begin
        \\{{var1}}
        \\{{var2}}
        \\{{myfunc({{var3}})}}
        \\end
    );
    var variables = KvStore{};
    try variables.add("var1", "value1");
    try variables.add("var2", "v2");
    try variables.add("var3", "woop");
    // var functions = [_]Pair{};

    var pairs = try findAllVariables(1024, MAX_VARIABLES, &str);
    try expandVariables(1024, MAX_VARIABLES, &str, &pairs, &variables);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{var1}}") == null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{var2}}") == null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{var3}}") == null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{myfunc") != null);

    try testing.expect(std.mem.indexOf(u8, str.slice(), "value1") != null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "v2") != null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "woop") != null);

    try expandFunctions(1024, MAX_VARIABLES, &str, &pairs);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{myfunc") == null);
}
