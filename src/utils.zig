const std = @import("std");
const testing = std.testing;

// Convenience-function to initiate a bounded-array without inital size of 0, removing the error-case brough by .init(size)
pub fn initBoundedArray(comptime T: type, comptime capacity: usize) std.BoundedArray(T, capacity) {
    return std.BoundedArray(T, capacity).init(0) catch unreachable;
}

/// Att! This adds a terminating zero at current .slice().len if there's capacity.
/// Capacity must be > 0
/// If not sufficient capacity: return null?
pub fn boundedArrayAsCstr(comptime capacity: usize, array: *std.BoundedArray(u8, capacity)) ![*]u8 {
    std.debug.assert(capacity > 0);
    if (array.constSlice().len >= capacity) return error.Overflow;

    array.buffer[array.constSlice().len] = 0;
    return array.slice().ptr;
}

test "boundedArrayAsCstr" {
    // { // Fails at compile-time, capacity==0 is invalid
    //     var str = initBoundedArray(u8, 0);
    //     var c_str = boundedArrayAsCstr(str.buffer.len, &str);
    //     try testing.expect(c_str[0] == 0);
    // }

    {
        var str = initBoundedArray(u8, 1);
        try str.appendSlice("A");
        try testing.expect(str.slice()[0] == 'A');
        try str.resize(0);
        var c_str = try boundedArrayAsCstr(str.buffer.len, &str);
        try testing.expect(c_str[0] == 0);
    }

    {
        var str = initBoundedArray(u8, 1);
        try str.appendSlice("A");
        try testing.expect(str.slice()[0] == 'A');
        try testing.expectError(error.Overflow, boundedArrayAsCstr(str.buffer.len, &str));
    }

    {
        var str = initBoundedArray(u8, 2);
        try str.appendSlice("AB");
        try testing.expect(str.slice()[0] == 'A');
        try testing.expect(str.slice()[1] == 'B');
        try str.resize(1);
        try testing.expect(str.slice().ptr[1] == 'B');
        var c_str = try boundedArrayAsCstr(str.buffer.len, &str);
        try testing.expect(c_str[0] == 'A');
        try testing.expect(c_str[1] == 0);
    }
}

/// UTILITY: Returns a slice from <from> up to <to> or slice.len
pub fn sliceUpTo(comptime T: type, slice: []T, from: usize, to: usize) []T {
    return slice[from..std.math.min(slice.len, to)];
}

pub fn constSliceUpTo(comptime T: type, slice: []const T, from: usize, to: usize) []const T {
    return slice[from..std.math.min(slice.len, to)];
}
