/// All tests shall start with "intgration:"
const std = @import("std");
const main = @import("main.zig");
const httpclient = @import("httpclient.zig");
const testing = std.testing;

test "integration: passing a well-formed .pi-file against healthy endpoint shall generate a successful result" {
    var args = [_][]const u8{
        "testdata/integrationtests/standalone/success.pi",
    };

    main.httpClientProcessEntry = httpclient.processEntry;
    var stats = try main.mainInner(testing.allocator, args[0..]);
    try testing.expect(stats.num_tests == 1);
    try testing.expect(stats.num_fail == 0);
    try testing.expect(stats.num_success == 1);
}

test "integration: passing a well-formed .pi-file against non-healthy endpoint shall generate an error result" {
    var args = [_][]const u8{
        "testdata/integrationtests/standalone/404.pi",
    };

    main.httpClientProcessEntry = httpclient.processEntry;
    var stats = try main.mainInner(testing.allocator, args[0..]);
    try testing.expect(stats.num_tests == 1);
    try testing.expect(stats.num_fail == 1);
    try testing.expect(stats.num_success == 0);
}

test "integration: suite with .env" {
    var args = [_][]const u8{
        "testdata/integrationtests/suite_with_env",
    };

    main.httpClientProcessEntry = httpclient.processEntry;
    var stats = try main.mainInner(testing.allocator, args[0..]);
    try testing.expect(stats.num_tests == 2);
    try testing.expect(stats.num_fail == 0);
    try testing.expect(stats.num_success == 2);
}

test "integration: requiring -Darg" {
    main.httpClientProcessEntry = httpclient.processEntry;

    {
        var args = [_][]const u8{
            "testdata/integrationtests/suite_requiring_-Darg",
        };

        var stats = try main.mainInner(testing.allocator, args[0..]);
        try testing.expect(stats.num_tests == 2);
        try testing.expect(stats.num_fail == 2);
        try testing.expect(stats.num_success == 0);
    }


    {
        var args = [_][]const u8{
            "testdata/integrationtests/suite_requiring_-Darg",
            "-DHOSTNAME=michaelodden.com"
        };

        var stats = try main.mainInner(testing.allocator, args[0..]);
        try testing.expect(stats.num_tests == 2);
        try testing.expect(stats.num_fail == 0);
        try testing.expect(stats.num_success == 2);
    }
}
