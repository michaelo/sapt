const ctregex = @import("libs/ctregex/ctregex.zig");
// const Regex = @import("libs/zig-regex/src/regex.zig").Regex;
const std = @import("std");
// const debug = std.debug;
const testing = std.testing;


test "ctregex" {
    // var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    // const gpa = &general_purpose_allocator.allocator;

    // var re = try Regex.compile(gpa, "\\d+");
    // try testing.expect((try re.match("123hej")) == true);
}

// test "string exploration" {
//     const str1 = "test";
//     var buf = initBoundedArray(u8, 64);

//     try testing.expect(buf.buffer.len == 64);
//     try testing.expect(str1.len == 4);
//     try testing.expect(buf.slice().len == 0);
//     try buf.insertSlice(0, str1);
//     try testing.expect(buf.slice().len == 4);
// }


// test "Casting to sentinel" {
//     var mystr = "hei";
//     var buf = initBoundedArray(u8, 128);
//     try buf.insertSlice(0, "hei");
//     try buf.append(0);
//     debug("type: {s}\n", .{@TypeOf(mystr)});
//     debug("type: {s}\n", .{@TypeOf(buf.slice())});


//     debug("type: {s}\n", .{@TypeOf(std.mem.sliceTo(&buf.buffer, 0))});
//     const sentinel_ptr = @ptrCast([*:0]u8, &buf.buffer);
//     debug("type: {s}\n", .{@TypeOf(sentinel_ptr)});

//     debug("value: {s}\n", .{buf.slice()});
//     debug("value: {s}\n", .{std.mem.sliceTo(sentinel_ptr, 0)});
// }

// test "string find" {
//     var mystr = "Woop di doo";
//     try testing.expect(null == std.mem.indexOf(u8, mystr, "dim"));
//     try testing.expect(5 == std.mem.indexOf(u8, mystr, "di").?);
// }