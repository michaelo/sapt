/// Basic writer supporting console-escape-codes for supported platforms
const std = @import("std");
pub const Color = std.debug.TTY.Color;

pub const Console = struct {
    const Self = @This();

    // Writers
    debug_writer: ?std.fs.File.Writer = null,
    std_writer: ?std.fs.File.Writer = null,
    error_writer: ?std.fs.File.Writer = null,
    verbose_writer: ?std.fs.File.Writer = null,

    ttyconf: std.debug.TTY.Config,

    pub fn initNull() Self {
        return Self {
            .ttyconf = std.debug.detectTTYConfig(),
        };
    }

    pub fn init(std_writer: ?std.fs.File.Writer, error_writer: ?std.fs.File.Writer, verbose_writer: ?std.fs.File.Writer, debug_writer: ?std.fs.File.Writer) Self {
        // TODO: Pass in config to determine if we shall use color codes or not
        return Self {
            .debug_writer = debug_writer,
            .std_writer = std_writer,
            .error_writer = error_writer,
            .verbose_writer = verbose_writer,
            .ttyconf = std.debug.detectTTYConfig(),
        };
    }

    pub fn printError(self: Self, comptime fmt:[]const u8, args: anytype) void {
        if(self.error_writer == null) return;
        self.ttyconf.setColor(self.error_writer.?, .Red);
        self.error_writer.?.print("ERROR: ", .{}) catch {};
        // TODO: Detect nl's, and indent following lines?
        self.ttyconf.setColor(self.error_writer.?, .Reset);
        self.error_writer.?.print(fmt, args) catch {};
    }

    pub fn printErrorNoPrefix(self: Self, comptime fmt:[]const u8, args: anytype) void {
        if(self.error_writer == null) return;
        // TODO: Detect nl's, and indent following lines?
        self.ttyconf.setColor(self.error_writer.?, .Reset);
        self.error_writer.?.print(fmt, args) catch {};
    }

    pub fn print(self: Self, comptime fmt:[]const u8, args: anytype) void {
        if(self.std_writer == null) return;
        self.ttyconf.setColor(self.std_writer.?, .Reset);
        self.std_writer.?.print(fmt, args) catch {};
    }

    pub fn verbose(self: Self, comptime fmt:[]const u8, args: anytype) void {
        if(self.verbose_writer == null) return;
        self.ttyconf.setColor(self.verbose_writer.?, .Reset);
        self.verbose_writer.?.print(fmt, args) catch {};
    }

    pub fn debug(self: Self, comptime fmt:[]const u8, args: anytype) void {
        if(self.debug_writer == null) return;
        self.ttyconf.setColor(self.debug_writer.?, .Dim);
        self.debug_writer.?.print(fmt, args) catch {};
        self.ttyconf.setColor(self.error_writer.?, .Reset);//? Or leave it to next line to do it properly
    }


    // Generic std_writer-users:

    /// Convenience-function to print only if condition is met
    pub fn printIf(self: Self, condition: bool, maybe_color: ?Color, comptime fmt:[]const u8, args: anytype) void {
        if(!condition) return;
        var color = maybe_color orelse .Reset;

        self.ttyconf.setColor(self.std_writer.?, color);
        self.std_writer.?.print(fmt, args) catch {};
        self.ttyconf.setColor(self.std_writer.?, .Reset);  
    }

    pub fn plain(self: Self, comptime fmt:[]const u8, args: anytype) void {
        self.ttyconf.setColor(self.std_writer.?, .Reset);
        self.std_writer.?.print(fmt, args) catch {};
        self.ttyconf.setColor(self.std_writer.?, .Reset);
    }

    pub fn grey(self: Self, comptime fmt:[]const u8, args: anytype) void {
        self.ttyconf.setColor(self.std_writer.?, .Dim);
        self.std_writer.?.print(fmt, args) catch {};
        self.ttyconf.setColor(self.std_writer.?, .Reset);
    }

    pub fn red(self: Self, comptime fmt:[]const u8, args: anytype) void {
        self.ttyconf.setColor(self.std_writer.?, .Red);
        self.std_writer.?.print(fmt, args) catch {};
        self.ttyconf.setColor(self.std_writer.?, .Reset);
    }

    pub fn green(self: Self, comptime fmt:[]const u8, args: anytype) void {
        self.ttyconf.setColor(self.std_writer.?, .Green);
        self.std_writer.?.print(fmt, args) catch {};
        self.ttyconf.setColor(self.std_writer.?, .Reset);
    }

    pub fn bold(self: Self, comptime fmt:[]const u8, args: anytype) void {
        self.ttyconf.setColor(self.std_writer.?, .Bold);
        self.std_writer.?.print(fmt, args) catch {};
        self.ttyconf.setColor(self.std_writer.?, .Reset);
    }
};

test "Console" {
    const stdout = std.io.getStdOut().writer();
    const c = Console.init(stdout,stdout,stdout,stdout);

    c.plain("Console.plain()\n", .{});
    c.grey("Console.grey()\n", .{});
    c.red("Console.red()\n", .{});
    c.green("Console.green()\n", .{});
    c.bold("Console.bold()\n", .{});
}

test "Console high" {
    const stdout = std.io.getStdOut().writer();
    const c = Console.init(stdout,stdout,stdout,stdout);
    c.print("\n", .{});

    c.printError("Something very wrong\n", .{});
    c.print("Regular output\n", .{});
    c.debug("Debug output\n", .{});
    c.verbose("Verbose output\n", .{});
}