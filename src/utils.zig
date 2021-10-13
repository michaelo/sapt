const std = @import("std");

// Convenience-function to initiate a bounded-array without inital size of 0, removing the error-case brough by .init(size)
pub fn initBoundedArray(comptime T: type, comptime capacity: usize) std.BoundedArray(T,capacity) {
    return std.BoundedArray(T, capacity){.buffer=undefined};
}

/// Att! This adds a terminating zero at current .slice().len TODO: Ensure there's space
pub fn boundedArrayAsCstr(comptime capacity: usize, array: *std.BoundedArray(u8, capacity)) [*]u8 {
    if(array.slice().len >= array.capacity()) unreachable;

    array.buffer[array.slice().len] = 0;
    return array.slice().ptr;
}

/// UTILITY: Returns a slice from <from> up to <to> or slice.len
pub fn sliceUpTo(comptime T: type, slice: []T, from: usize, to: usize) []T {
    return slice[from..std.math.min(slice.len, to)];
}