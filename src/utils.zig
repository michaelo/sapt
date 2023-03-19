const std = @import("std");
const testing = std.testing;

// Convenience-function to initiate a bounded-array without inital size of 0, removing the error-case brough by .init(size)
pub fn initBoundedArray(comptime T: type, comptime capacity: usize) std.BoundedArray(T, capacity) {
    return std.BoundedArray(T, capacity).init(0) catch unreachable;
}


/// UTILITY: Returns a slice from <from> up to <to> or slice.len
pub fn sliceUpTo(comptime T: type, slice: []T, from: usize, to: usize) []T {
    return slice[from..std.math.min(slice.len, to)];
}

pub fn constSliceUpTo(comptime T: type, slice: []const T, from: usize, to: usize) []const T {
    return slice[from..std.math.min(slice.len, to)];
}

// TODO: Are there any stdlib-variants of this?
pub fn addUnsignedSigned(comptime UnsignedType: type, comptime SignedType: type, base: UnsignedType, delta: SignedType) !UnsignedType {
    if (delta >= 0) {
        return std.math.add(UnsignedType, base, std.math.absCast(delta));
    } else {
        return std.math.sub(UnsignedType, base, std.math.absCast(delta));
    }
}

test "addUnsignedSigned" {
    try testing.expect((try addUnsignedSigned(u64, i64, 1, 1)) == 2);
    try testing.expect((try addUnsignedSigned(u64, i64, 1, -1)) == 0);
    try testing.expectError(error.Overflow, addUnsignedSigned(u64, i64, 0, -1));
    try testing.expectError(error.Overflow, addUnsignedSigned(u64, i64, std.math.maxInt(u64), 1));
}
