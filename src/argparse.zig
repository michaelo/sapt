const std = @import("std");
const debug = std.debug.print;
const testing = std.testing;
const fs = std.fs;
const main = @import("main.zig");
const config = @import("config.zig");
const AppArguments = main.AppArguments;
const FilePathEntry = main.FilePathEntry;

pub fn printHelp(full: bool) void {
    debug(
        \\
        \\{0s} v{1s} - Simple API Tester
        \\
        \\Usage: {0s} [arguments] file1 [file2 ... fileN]
        \\
    , .{ config.APP_NAME, config.APP_VERSION });

    if (!full) return;

    debug(
        \\{0s} gettoken.pi testsuite1/*
        \\{0s} -p=myplaybook.book
        \\{0s} -p=myplaybook.book -s -o=output.log
        \\{0s} -i=testsuite01/.env testsuite01
        \\
        \\Arguments
        \\  -h           Show this help
        // \\  --test-help
        // \\  --playbook-help
        \\  -v           Verbose
        \\  -r           Recursive -- not implemented yet
        \\  -s           Silent -- not implemented yet
        \\  -d           Show response data
        \\  -m           Activates multithreading - relevant for repeated tests via 
        \\               playbooks.
        \\  -i=file      Input-variables file
        \\  -o=file      Redirect all output to file
        \\  -p=playbook  Read tests to perform from playbook-file -- if set, ignores
        \\               other tests passed as arguments. Will later autosense
        \\               based on extension instead if dedicated flag.
        \\
    , .{config.APP_NAME});
}

pub fn parseArgs(args: [][]const u8) !AppArguments {
    var result: AppArguments = .{};

    for (args) |arg| {
        // Handle flags (-v, -s, ...)
        // Handle arguments with values (-o=...)
        // Handle rest (file/folder-arguments)
        // TODO: Revise to have a flat list of explicit checks, but split at = for such entries when comparing
        if (arg[0] == '-') {
            switch (arg.len) {
                0...1 => {
                    return error.UnknownArgument;
                },
                2 => {
                    switch (arg[1]) {
                        'h' => {
                            return error.ShowHelp;
                        },
                        'v' => {
                            result.verbose = true;
                        },
                        'r' => {
                            result.recursive = true;
                        },
                        's' => {
                            result.silent = true;
                        },
                        'd' => {
                            result.show_response_data = true;
                        },
                        'm' => {
                            result.multithreaded = true;
                        },
                        else => {
                            return error.UnknownArgument;
                        },
                    }
                },
                else => {
                    // Parse key=value-types
                    var eq_pos = std.mem.indexOf(u8, arg, "=") orelse return error.InvalidArgumentFormat;

                    var key = arg[1..eq_pos];
                    var value = arg[eq_pos + 1 ..];


                    if (std.mem.eql(u8, key, "o")) {
                        try result.output_file.appendSlice(value);
                    } else if (std.mem.eql(u8, key, "i")) {
                        try result.input_vars_file.appendSlice(value);
                    } else if (std.mem.eql(u8, key, "p")) {
                        try result.playbook_file.appendSlice(value);
                    }

                },
            }
        } else {
            // Is (assumed) file/folder
            // TODO: Shall we here expand folders?
            //       Alternatively, we can process this separately, add all entries to result.files and finally sort it by name
            result.files.append(FilePathEntry.fromSlice(arg) catch {
                return error.TooLongFilename;
            }) catch {
                return error.TooManyFiles;
            };
        }
    }

    return result;
}

test "parseArgs" {
    const default_args: AppArguments = .{};

    {
        var myargs = [_][]const u8{};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.verbose == default_args.verbose);
    }

    {
        var myargs = [_][]const u8{"-v"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.verbose);
    }

    {
        var myargs = [_][]const u8{"-r"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.recursive);
    }

    {
        var myargs = [_][]const u8{"-s"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.silent);
    }

    {
        var myargs = [_][]const u8{"-m"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.multithreaded);
    }

    {
        var myargs = [_][]const u8{"somefile"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.files.slice().len == 1);
        try testing.expectEqualStrings("somefile", parsed_args.files.get(0).slice());
    }

    {
        var myargs = [_][]const u8{"-o=myoutfile"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expectEqualStrings("myoutfile", parsed_args.output_file.slice());
    }

    {
        var myargs = [_][]const u8{"-p=myplaybook"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expectEqualStrings("myplaybook", parsed_args.playbook_file.slice());
    }
}

pub fn processInputFileArguments(comptime max_files: usize, files: *std.BoundedArray(FilePathEntry, max_files)) !void {
    // Fail on files not matching expected name-pattern
    // Expand folders
    // Verify that files exists and are readable
    var cwd = fs.cwd();
    const readFlags = std.fs.File.OpenFlags{ .read = true };
    {
        var i: usize = 0;
        var file: *FilePathEntry = undefined;
        while (i < files.slice().len) : (i += 1) {
            file = &files.get(i);
            // debug("Processing: {s}\n", .{file.slice()}); # TODO:
            // Verify that file/folder exists, otherwise fail
            cwd.access(file.constSlice(), readFlags) catch {
                debug("Can not access '{s}'\n", .{file.slice()});
                return error.NoSuchFileOrFolder;
            };

            // Try to open as dir
            var dir = cwd.openDir(file.constSlice(), .{ .iterate = true }) catch |e| switch (e) {
                // Not a dir, that's OK
                error.NotDir => continue,
                else => return error.UnknownError,
            };
            defer dir.close();

            var d_it = dir.iterate();
            while (try d_it.next()) |a_path| {
                var stat = try (try dir.openFile(a_path.name, readFlags)).stat();
                switch (stat.kind) {
                    .File => {
                        // TODO: Ignore .env and non-.pi files here?
                        // TODO: If we shall support .env-files pr folder/suite, then we will perhaps need to keep track of "suites" internally as well?

                        var item = main.initBoundedArray(u8, config.MAX_PATH_LEN);
                        try item.appendSlice(file.constSlice());
                        try item.appendSlice("/");
                        try item.appendSlice(a_path.name);
                        // Add to files
                        try files.append(item);
                    },
                    .Directory => {
                        debug("Found subdir: {s}\n", .{a_path.name});
                        // If recursive: process
                    },
                    else => {},
                }
            }
        }
    }

    // Remove all folders
    for (files.slice()) |file, i| {
        _ = cwd.openDir(file.constSlice(), .{ .iterate = true }) catch {
            // Not a dir, leave alone
            continue;
        };

        // Dir, remove
        _ = files.swapRemove(i);
    }

    // Sort the remainding entries
    std.sort.sort(FilePathEntry, files.slice(), {}, struct {
        fn func(context: void, a: FilePathEntry, b: FilePathEntry) bool {
            _ = context;
            return std.mem.lessThan(u8, a.constSlice(), b.constSlice());
        }
    }.func);
}

test "processInputFileArguments" {
    var files: std.BoundedArray(FilePathEntry, 128) = main.initBoundedArray(FilePathEntry, 128);
    try files.append(try FilePathEntry.fromSlice("testdata/01-warnme"));

    try processInputFileArguments(128, &files);

    // TODO: Verify all elements are parsed and in proper order
    // Cases:
    //   * If file, no need to expand
    //   * If folder and no -r, expand contents only one leve
    //   * If folder and -r, expand end recurse
}
