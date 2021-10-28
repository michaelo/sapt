const std = @import("std");
const fs = std.fs;
const testing = std.testing;

/// Reads contents from path, relative to cwd, and store in target_buf
pub fn readFileRaw(path: []const u8, target_buf: []u8) !usize {
    return try readFileRawRel(fs.cwd(), path, target_buf);
}

/// Reads contents from path, relative to dir, and store in target_buf
pub fn readFileRawRel(dir: std.fs.Dir, path: []const u8, target_buf: []u8) !usize {
    var file = try dir.openFile(path, .{ .read = true });
    defer file.close();

    return try file.readAll(target_buf[0..]);
}

test "readFileRaw" {
    var buf = try std.BoundedArray(u8, 1024 * 1024).init(0);
    try testing.expect(buf.slice().len == 0);
    try buf.resize(try readFileRaw("testdata/01-warnme/01-warnme-status-ok.pi", buf.buffer[0..]));
    try testing.expect(buf.slice().len > 0);
}

/// Reads contents from path, relative to cwd, and store in target_buf
pub fn readFile(comptime S: usize, path: []const u8, target_buf: *std.BoundedArray(u8, S)) !void {
    return try readFileRel(S, fs.cwd(), path, target_buf);
}

/// Reads contents from path, relative to dir, and store in target_buf
pub fn readFileRel(comptime S: usize, dir: std.fs.Dir, path: []const u8, target_buf: *std.BoundedArray(u8, S)) !void {
    var file = try dir.openFile(path, .{ .read = true });
    defer file.close();

    const size = try file.getEndPos();
    try target_buf.resize(std.math.min(size, target_buf.capacity()));
    _ = try file.readAll(target_buf.slice()[0..]);
}

// test "readfile rel" {
//     std.debug.print("\nwoop\n", .{});
//     var buf = utils.initBoundedArray(u8, 1024 * 1024);
//     var dir = try std.fs.cwd().openDir("src", .{});
//     std.debug.print("dir: {s}\n", .{dir});
//     try readFileRel(buf.buffer.len, dir, "../VERSION", &buf);
//     std.debug.print("Contents: {s}\n", .{buf.slice()});
// }

test "realpath - got issues" {
    var scrap: [2048]u8 = undefined;
    // std.fs.realpath
    // These two examples provides the same result... (ZIGBUG?)
    {
        var dir = try std.fs.cwd().openDir("src", .{});
        var realpath = try dir.realpath("..", scrap[0..]);
        std.debug.print("realpath: {s}\n", .{realpath});
    }
    {
        var dir = std.fs.cwd();
        var realpath = try dir.realpath("..", scrap[0..]);
        std.debug.print("realpath: {s}\n", .{realpath});
    }
}

/// Needed as there are some quirks with folder-resolution, at least for Windows.
/// TODO: investigate and file bug/PR
pub fn getRealPath(base: []const u8, sub: []const u8, scrap: []u8) ![]u8 {
    // Blank base == cwd
    var tmp_result = if (base.len > 0) try std.fmt.bufPrint(scrap[0..], "{s}/{s}", .{ base, sub }) else try std.fmt.bufPrint(scrap[0..], "./{s}", .{sub});
    var result = try std.fs.cwd().realpath(tmp_result, scrap[0..]);
    return result;
}

// test "getRealPath" {
//     var base_path = "src";
//     var sub_path = "../VERSION";

//     var scrap: [2048]u8 = undefined;
//     var result = try getRealPath(base_path, sub_path, scrap[0..]);
//     std.debug.print("result: {s}\n", .{result});
// }

test "readFile" {
    var buf = try std.BoundedArray(u8, 1024 * 1024).init(0);
    try testing.expect(buf.slice().len == 0);
    try readFile(buf.buffer.len, "testdata/01-warnme/01-warnme-status-ok.pi", &buf);
    try testing.expect(buf.slice().len > 0);
}

/// Autosense buffer for type of line ending: Check buf for \r\n, and if found: return \r\n, otherwise \n
pub fn getLineEnding(buf: []const u8) []const u8 {
    if (std.mem.indexOf(u8, buf, "\r\n") != null) return "\r\n";
    return "\n";
}

/// Returns the slice which is without the last path-segment
pub fn getParent(fileOrDir: []const u8) []const u8 {
    std.debug.assert(fileOrDir.len > 0);
    var i: usize = fileOrDir.len - 2;
    while (i > 0) : (i -= 1) {
        if (fileOrDir[i] == '/' or fileOrDir[i] == '\\') {
            break;
        }
    }
    return fileOrDir[0..i];
}

test "getParent" {
    try testing.expectEqualStrings("", getParent("myfile"));
    try testing.expectEqualStrings("folder", getParent("folder/file"));
}
