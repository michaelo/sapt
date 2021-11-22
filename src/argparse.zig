const std = @import("std");
const debug = std.debug.print;
const testing = std.testing;
const fs = std.fs;
const main = @import("main.zig");
const utils = @import("utils.zig");
const config = @import("config.zig");
const kvstore = @import("kvstore.zig");
const Console = @import("console.zig").Console;

pub const FilePathEntry = std.BoundedArray(u8, config.MAX_PATH_LEN);

pub const AppArguments = struct {
    //--colors
    colors: Console.ColorConfig = .auto,
    //--verbose,-v
    verbose: bool = false,
    //--verbose-curl TODO: Rename to --verbose-http / --verbose-request ?
    verbose_curl: bool = false,
    //-s
    silent: bool = false,
    //--insecure
    ssl_insecure: bool = false,
    //--show-response,-d
    show_response_data: bool = false,
    //--pretty,-p
    show_pretty_response_data: bool = false,
    //-m allows for concurrent requests for repeated tests
    multithreaded: bool = false,
    //-e, --early-quit - abort execution upon first non-successful test
    early_quit: bool = false,
    //-i=<file>
    input_vars_file: std.BoundedArray(u8, config.MAX_PATH_LEN) = utils.initBoundedArray(u8, config.MAX_PATH_LEN),
    //-b=<file>
    playbook_file: std.BoundedArray(u8, config.MAX_PATH_LEN) = utils.initBoundedArray(u8, config.MAX_PATH_LEN),
    //-delay=NN
    delay: u64 = 0,
    // ...
    files: std.BoundedArray(FilePathEntry, 128) = utils.initBoundedArray(FilePathEntry, 128),
};

pub fn printHelp(full: bool) void {
    debug(
        \\{0s} v{1s} - Simple API Tester
        \\
        \\Usage: {0s} [arguments] [file1.pi file2.pi ... fileN.pi]
        \\
        \\
        , .{ config.APP_NAME, config.APP_VERSION});

    if (!full) {
        debug(
            \\try '{0s} --help' for more information.
            \\
            \\
            , .{ config.APP_NAME});
        return;
    }
    
    debug(
        \\Examples:
        \\  {0s} api_is_healthy.pi
        \\  {0s} testsuite01/
        \\  {0s} -b=myplaybook.book
//        \\  {0s} -p=myplaybook.book -s -o=output.log
        \\  {0s} -i=generaldefs/.env testsuite01/
        \\
        \\Arguments:
        \\      --colors=auto|on|off Set wether to attempt to use colored output or not
        \\      --delay=NN          Delay execution of each consecutive step with NN ms
        \\  -e, --early-quit        Abort upon first non-successful test
        \\  -h, --help              Show this help and exit
        \\      --help-format       Show details regarding file formats and exit
        \\  -i=file,
        \\      --initial-vars=file Provide file with variable-definitions made available
        \\                          to all tests
        \\      --insecure          Don't verify SSL certificates
        \\  -m, --multithread       Activates multithreading - relevant for repeated
        \\                          tests via playbooks
        \\  -p, --pretty            Try to format response data based on Content-Type.
        \\                          Naive support for JSON, XML and HTML
        \\  -b=file,
        \\      --playbook=file     Read tests to perform from playbook-file -- if set,
        \\                          ignores other tests passed as arguments
        \\  -d, --show-response     Show response data. Even if -s.
        \\  -s, --silent            Silent. Suppresses output. Overrules verbose.
        \\  -v, --verbose           Verbose output
        \\      --verbose-curl      Verbose output from libcurl
        \\      --version           Show version and exit
        \\
        \\  -DKEY=VALUE             Define variable, similar to .env-files. Can be set
        \\                          multiple times
        \\
    , .{config.APP_NAME});
}

pub fn printFormatHelp() void {
    debug(
        \\{0s} v{1s} - Simple API Tester - format help
        \\  For more details, please see: https://github.com/michaelo/sapt/
        \\
        \\Variable-files (must have extension .env):
        \\  MYVAR=value
        \\  USERNAME=Admin
        \\  PASSWORD=SuperSecret
        \\
        \\Test-files (must have extension .pi):
        \\  > GET https://example.com/
        \\  < 200
        \\
        \\  > POST https://example.com/protected/upload
        \\  Authorization: Basic {{{{base64enc({{{{USERNAME}}}}:{{{{PASSWORD}}}})}}}}
        \\  Content-Type: application/x-www-form-urlencoded
        \\  --
        \\  field=value&field2=othervalue
        \\  < 200 string_that_must_be_found_to_be_considered_success
        \\  # Extraction entries:
        \\  # A variable will be created if the rightmost expression is found. '()' is
        \\  # a placeholder for the value to extract.
        \\  # E.g. if the response is: id=123&result=true, then the following will create
        \\  # a variable named "RESULT_ID" with the value "123", which can be reused in
        \\  # later tests:
        \\  RESULT_ID=id=()&result=true
        \\
        \\Playbook-files (recommended to have extension .book):
        \\  # Import variables from file which can be accessed in any following tests
        \\  @../globals/some_env_file.env
        \\ 
        \\  # Define variable which can be accessed in any following tests
        \\  SOME_VAR=value
        \\ 
        \\  # Import/execute test from file
        \\  @my_test.pi
        \\ 
        \\  # Att: imports are relative to playbook
        \\ 
        \\  # In-file test, format just as in .pi-files
        \\  > GET https://example.com/
        \\  < 200
        \\
        \\Functions:
        \\ sapt has a couple convenience-functions that can be used in tests and variable-definitions
        \\ * {{{{base64enc(value)}}}} - base64-encodes the value
        \\ * {{{{env(key)}}}} - attempts to look up the environment-variable 'key' from the operating system.
        \\
        \\
        , .{config.APP_NAME, config.APP_VERSION});
}

fn argIs(arg: []const u8, full: []const u8, short: ?[]const u8) bool {
    return std.mem.eql(u8, arg, full) or std.mem.eql(u8, arg, short orelse "XXX");
}

fn argHasValue(arg: []const u8, full: []const u8, short: ?[]const u8) ?[]const u8 {
    var eq_pos = std.mem.indexOf(u8, arg, "=") orelse return null;

    var key = arg[0..eq_pos];

    if(argIs(key, full, short)) {
        return arg[eq_pos + 1 ..];
    } else return null;
}

test "argIs" {
    try testing.expect(argIs("--verbose", "--verbose", "-v"));
    try testing.expect(argIs("-v", "--verbose", "-v"));
    try testing.expect(!argIs("--something-else", "--verbose", "-v"));

    try testing.expect(argIs("--verbose", "--verbose", null));
    try testing.expect(!argIs("-v", "--verbose", null));
}


test "argHasValue" {
    try testing.expect(argHasValue("--playbook=mybook", "--playbook", "-b") != null);
    try testing.expect(argHasValue("-b=mybook", "--playbook", "-b") != null);
}

pub fn parseArgs(args: [][]const u8, maybe_variables: ?*kvstore.KvStore) !AppArguments {
    var result: AppArguments = .{};

    if(args.len < 1) {
        return error.NoArguments;
    }

    for (args) |arg| {
        // Flags
        if(argIs(arg, "--help", "-h")) {
            printHelp(true);
            return error.OkExit;
        }

        if(argIs(arg, "--help-format", null)) {
            printFormatHelp();
            return error.OkExit;
        }

        if(argIs(arg, "--version", null)) {
            debug("{0s} v{1s}\n", .{config.APP_NAME, config.APP_VERSION});
            return error.OkExit;
        }

        if(argIs(arg, "--multithread", "-m")) {
            result.multithreaded = true;
            continue;
        }

        if(argIs(arg, "--early-quit", "-e")) {
            result.early_quit = true;
            continue;
        }
        
        if(argIs(arg, "--pretty", "-p")) {
            result.show_pretty_response_data = true;
            continue;
        }

        if(argIs(arg, "--show-response", "-d")) {
            result.show_response_data = true;
            continue;
        }

        if(argIs(arg, "--silent", "-s")) {
            result.silent = true;
            result.verbose = false;
            continue;
        }

        if(!result.silent and argIs(arg, "--verbose", "-v")) {
            result.verbose = true;
            continue;
        }

        if(!result.silent and argIs(arg, "--verbose-curl", null)) {
            result.verbose_curl = true;
            continue;
        }

        if(argIs(arg, "--insecure", null)) {
            result.ssl_insecure = true;
            continue;
        }

        // Value-parameters
        if(argHasValue(arg, "--initial-vars", "-i")) |value| {
            try result.input_vars_file.appendSlice(value);
            continue;
        }

        if(argHasValue(arg, "--playbook", "-b")) |value| {
            try result.playbook_file.appendSlice(value);
            continue;
        }

        if(argHasValue(arg, "--delay", null)) |value| {
            result.delay = std.fmt.parseUnsigned(u64, value, 10) catch {
                debug("WARNING: Could not parse value of {s} as a positive number\n", .{arg});
                return error.InvalidArgument;
            };
            continue;
        }

        if(argHasValue(arg, "--colors", null)) |value| {
            result.colors = std.meta.stringToEnum(Console.ColorConfig, value) orelse return error.InvalidArgument;
            continue;
        }


        if(maybe_variables) |variables| if(std.mem.startsWith(u8, arg, "-D")) {
            // Found variable-entry
            try variables.addFromBuffer(arg[2..], .KeepFirst);
            continue;
        };

        // Assume ordinary files
        result.files.append(FilePathEntry.fromSlice(arg) catch {
            return error.TooLongFilename;
        }) catch {
            return error.TooManyFiles;
        };
    }

    return result;
}

test "parseArgs colors" {
    // Default
    {
        var myargs = [_][]const u8{"dummyarg"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expectEqual(Console.ColorConfig.auto, parsed_args.colors);
    }
    // Checking all alternatives
    {
        var myargs = [_][]const u8{"--colors=auto"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expectEqual(Console.ColorConfig.auto, parsed_args.colors);
    }
    {
        var myargs = [_][]const u8{"--colors=on"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expectEqual(Console.ColorConfig.on, parsed_args.colors);
    }
    {
        var myargs = [_][]const u8{"--colors=off"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expectEqual(Console.ColorConfig.off, parsed_args.colors);
    }
    {
        var myargs = [_][]const u8{"--colors=blah"};
        try testing.expectError(error.InvalidArgument, parseArgs(myargs[0..], null));
    }
}

test "parseArgs verbosity" {
    {
        var myargs = [_][]const u8{"dummyarg"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(!parsed_args.verbose);
        try testing.expect(!parsed_args.verbose_curl);
    }
    {
        var myargs = [_][]const u8{"-v"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.verbose);
    }
    {
        var myargs = [_][]const u8{"--verbose"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.verbose);
    }
    {
        var myargs = [_][]const u8{"--verbose-curl"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.verbose_curl);
    }
}

test "parseArgs multithread" {
    {
        var myargs = [_][]const u8{"dummyarg"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(!parsed_args.multithreaded);
    }
    {
        var myargs = [_][]const u8{"-m"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.multithreaded);
    }
    {
        var myargs = [_][]const u8{"--multithread"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.multithreaded);
    }
}

test "parseArgs playbook" {
    {
        var myargs = [_][]const u8{"dummyarg"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.playbook_file.slice().len == 0);
    }
    {
        var myargs = [_][]const u8{"-b=myplaybook"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expectEqualStrings("myplaybook", parsed_args.playbook_file.slice());
    }

    {
        var myargs = [_][]const u8{"--playbook=myplaybook"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expectEqualStrings("myplaybook", parsed_args.playbook_file.slice());
    }
}


test "parseArgs input vars" {
    {
        var myargs = [_][]const u8{"dummyarg"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.input_vars_file.slice().len == 0);
    }
    {
        var myargs = [_][]const u8{"-i=myvars.env"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expectEqualStrings("myvars.env", parsed_args.input_vars_file.slice());
    }

    {
        var myargs = [_][]const u8{"--initial-vars=myvars.env"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expectEqualStrings("myvars.env", parsed_args.input_vars_file.slice());
    }
}

test "parseArgs show response" {
    {
        var myargs = [_][]const u8{"dummyarg"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(!parsed_args.show_response_data);
    }
    {
        var myargs = [_][]const u8{"-d"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.show_response_data);
    }
    {
        var myargs = [_][]const u8{"--show-response"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.show_response_data);
    }
}

test "parseArgs pretty" {
    {
        var myargs = [_][]const u8{"dummyarg"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(!parsed_args.show_pretty_response_data);
    }
    {
        var myargs = [_][]const u8{"-p"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.show_pretty_response_data);
    }
    {
        var myargs = [_][]const u8{"--pretty"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.show_pretty_response_data);
    }
}


test "parseArgs early-quit" {
    {
        var myargs = [_][]const u8{"dummyarg"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(!parsed_args.early_quit);
    }
    {
        var myargs = [_][]const u8{"-e"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.early_quit);
    }
    {
        var myargs = [_][]const u8{"--early-quit"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.early_quit);
    }
}

test "parseArgs showHelp" {
    {
        var myargs = [_][]const u8{"-h"};
        try testing.expectError(error.OkExit, parseArgs(myargs[0..], null));

    }
    {
        var myargs = [_][]const u8{"--help"};
        try testing.expectError(error.OkExit, parseArgs(myargs[0..], null));
    }
}

test "parseArgs files" {
    {
        var myargs = [_][]const u8{"somefile"};
        var parsed_args = try parseArgs(myargs[0..], null);
        try testing.expect(parsed_args.files.slice().len == 1);
        try testing.expectEqualStrings("somefile", parsed_args.files.get(0).slice());
    }
}

test "parseArgs -DKEY=VALUE" {
    {
        var myargs = [_][]const u8{"-DKEY=VALUE"};
        var variables = kvstore.KvStore{};
        _ = try parseArgs(myargs[0..], &variables);
        try testing.expect(variables.slice().len == 1);
        try testing.expectEqualStrings("VALUE", variables.get("KEY").?);
    }
}

/// For debug
fn dumpFileList(files: []FilePathEntry) void {
    for (files) |itm, idx| {
        debug("{d}: {s}\n", .{idx, itm.constSlice()});
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
            var dir_slice_start = i;
            while (try d_it.next()) |a_path| {
                var stat = try (try dir.openFile(a_path.name, readFlags)).stat();
                switch (stat.kind) {
                    .File => {
                        var item = utils.initBoundedArray(u8, config.MAX_PATH_LEN);
                        try item.appendSlice(file.constSlice());
                        try item.appendSlice("/");
                        try item.appendSlice(a_path.name);
                        // Add to files at spot of folder - pushing it further back in the list
                        try files.insert(i, item);
                        i+=1;
                    },
                    .Directory => {
                        // debug("Found subdir: {s}\n", .{a_path.name});
                        // If recursive: process?
                    },
                    else => {},
                }
            }

            // Remove folder entry - don't need it
            _= files.orderedRemove(i);
            i -= 1;

            // Ensure folder-entries is sorted
            std.sort.sort(FilePathEntry, files.slice()[dir_slice_start..i+1], {}, struct {
                fn func(context: void, a: FilePathEntry, b: FilePathEntry) bool {
                    _ = context;
                    return std.mem.lessThan(u8, a.constSlice(), b.constSlice());
                }
            }.func);
        }
    }
}

test "processInputFileArguments" {
    var files: std.BoundedArray(FilePathEntry, 128) = utils.initBoundedArray(FilePathEntry, 128);
    try files.append(try FilePathEntry.fromSlice("testdata/01-warnme"));

    try processInputFileArguments(128, &files);

    // TODO: Verify all elements are parsed and in proper order
    // Cases:
    //   * If file, no need to expand
    //   * If folder and no -r, expand contents only one leve
    //   * If folder and -r, expand end recurse
}
