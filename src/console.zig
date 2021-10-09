/// Basic contextual output-handlers supporting console-escape-codes for supported platforms
/// Each function ends with reset
/// TODO: Name by color or by semantics? Alternatively both.
// NO_COLOR env
// std.debug.detectTTYConfig()
//
//  const ttyconf: std.debug.TTY.Config = switch (color) {
//        .auto => std.debug.detectTTYConfig(),
//        .on => .escape_codes,
//        .off => .no_color,
//    };

const std = @import("std");
const print = std.debug.print;
const os = @import("builtin").target.os;

pub const Console = struct {

    pub fn reset() void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Reset);
    }

    pub fn plain(comptime fmt:[]const u8, args: anytype) void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Reset);
        stdout.print(fmt, args) catch {};
        ttyconf.setColor(stdout, .Reset);
    }

    pub fn grey(comptime fmt:[]const u8, args: anytype) void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Dim);
        stdout.print(fmt, args) catch {};
        ttyconf.setColor(stdout, .Reset);
    }

    pub fn red(comptime fmt:[]const u8, args: anytype) void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Red);
        stdout.print(fmt, args) catch {};
        ttyconf.setColor(stdout, .Reset);
    }

    pub fn green(comptime fmt:[]const u8, args: anytype) void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Green);
        stdout.print(fmt, args) catch {};
        ttyconf.setColor(stdout, .Reset);
    }

    pub fn bold(comptime fmt:[]const u8, args: anytype) void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Green);
        stdout.print(fmt, args) catch {};
        ttyconf.setColor(stdout, .Reset);
    }

    pub fn nl() void {
        const stdout = std.io.getStdOut().writer();
        // var ttyconf = std.debug.detectTTYConfig();

        stdout.writeAll("\n");
    }
};

test "Console" {
    const c = Console;
    c.plain("plain\n", .{});
    c.grey("grey\n", .{});
    c.red("red\n", .{});
    c.green("green\n", .{});
}
