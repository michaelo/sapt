/// Module with functions to simple and efficiently provide a pretty-ish view of certain data types: JSON, XML and HTML.
/// This is intentionally not focused on perfect formatting, and will not employ full tokenizing and such techniques to achieve this.
/// This is simply intended as a quick way to make the content returned somewhat more easy to inspect.
/// So, DISCLAIMER: Don't uncritically rely on the formatted output. If in doubt - check the raw response. 
/// This is also why formatted output should not be on by default.
/// 
/// TBD: Should functions take File-reference, or just always print to stdout?
/// TBD: Support basic syntax highlighting as well?
const std = @import("std");
const stdout = std.io.getStdOut().writer();
const testing = std.testing;
const debug = std.debug.print;
const Writer = std.fs.File.Writer;

fn nl(writer: Writer, num: i64) !void {
    var i = num;
    // TODO: Support CRLF for Win?
    try writer.print("\n", .{});
    while (i > 0) : (i -= 1) try writer.print(" ", .{});
}

fn isJsonType(content_type: []const u8) bool {
    const types_chunk = [_][]const u8{
        "/json",
    };

    for (types_chunk) |end| {
        if (std.mem.indexOf(u8, content_type, end) != null) return true;
    }
    return false;
}

fn isXml(content_type: []const u8) bool {
    const types_chunk = [_][]const u8{ "/xml", "+xml" };

    for (types_chunk) |end| {
        if (std.mem.indexOf(u8, content_type, end) != null) return true;
    }
    return false;
}

fn isHtmlLike(content_type: []const u8) bool {
    const types_chunk = [_][]const u8{"/html"};

    for (types_chunk) |end| {
        if (std.mem.indexOf(u8, content_type, end) != null) return true;
    }
    return false;
}

test "isJsonType" {
    try testing.expect(isJsonType("application/json"));
    try testing.expect(!isJsonType("text/html"));
    try testing.expect(!isJsonType("text/xml"));
}

test "isHtmlLike" {
    try testing.expect(!isHtmlLike("application/json"));
    try testing.expect(isHtmlLike("text/html"));
    try testing.expect(!isHtmlLike("text/xml"));
    try testing.expect(!isHtmlLike("application/xml"));
    try testing.expect(!isHtmlLike("application/xhtml+xml"));
}

test "isXml" {
    try testing.expect(!isXml("application/json"));
    try testing.expect(!isXml("text/html"));
    try testing.expect(isXml("text/xml"));
    try testing.expect(isXml("application/xml"));
    try testing.expect(isXml("application/xhtml+xml"));
}

pub fn getPrettyPrinterByContentType(content_type: []const u8) fn (Writer, []const u8) anyerror!void {
    if (isJsonType(content_type)) return prettyprintJson;
    if (isXml(content_type)) return prettyprintXml;
    if (isHtmlLike(content_type)) return prettyprintHtml;
    return passthrough;
}

test "getPrettyPrinterByContentType" {
    try testing.expectEqual(prettyprintJson, getPrettyPrinterByContentType("application/json"));
    try testing.expectEqual(prettyprintHtml, getPrettyPrinterByContentType("text/html"));
    try testing.expectEqual(prettyprintXml, getPrettyPrinterByContentType("text/xml"));
    try testing.expectEqual(passthrough, getPrettyPrinterByContentType("something/else"));
}

/// Simple passes through with not formatting actions
fn passthrough(writer: Writer, data: []const u8) !void {
    try writer.writeAll(data);
}

/// Super-naive pretty-printer for JSON data
/// Assumes a string of well-formed JSON and attempts to print it in a human readable structure
fn prettyprintJson(writer: Writer, data: []const u8) anyerror!void {
    // Assume well-structured json - do an as-simple-as-possible pretty-print without semantically parsing
    // For each new line, start with padding the indent_level
    // var specialStack = try std.BoundedArray(Specials, 128).init(0);
    // Need to look ahead;

    var indent_level: i64 = 0;
    // TBD: This currently only makes sense if the content has no formatting...´
    //      We should check if the desired additional chars we output is not already at the expected location. ie: printIfNotNext(...). And outside of quotes: ignore all whitespace
    // var in_string = false;
    var i:usize = 0;
    while (i < data.len) : (i += 1) {
        var char = data[i];
        switch (char) {
            '{' => {
                indent_level += 4;
                try writer.print("{c}", .{char});
                try nl(writer, indent_level);
            },
            '}' => {
                indent_level -= 4;
                try nl(writer, indent_level);
                try writer.print("{c}", .{char});
            },
            '[' => {
                indent_level += 4;
                try writer.print("{c}", .{char});
                try nl(writer, indent_level);
            },
            ']' => {
                indent_level -= 4;
                try nl(writer, indent_level);
                try writer.print("{c}", .{char});
            },
            ':' => {
                try writer.print("{c} ", .{char});
            },
            ',' => {
                try writer.print("{c}", .{char});
                try nl(writer, indent_level);
            },
            '"' => {
                // Dump all until first non-escaped "
                try writer.print("{c}", .{data[i]});
                i+=1;
                while (i>0 and !(data[i] == '"' and data[i - 1] != '\\')) : ( i += 1 ) {
                    // continue;
                    try writer.print("{c}", .{data[i]});
                }
                try writer.print("{c}", .{data[i]});
            },
            ' ', '\t', '\n' => {
                continue;
            },
            else => {
                try writer.print("{c}", .{char});
            },
        }
    }
    
    try writer.writeAll("\n");
}

test "pretty-print JSON" {
    {
        var data =
            \\{"key":"value","key2":[1,2,3],"key3":{},"key4":5,"key5":[{},{"inner":["hepp"]}]}
        ;

        try prettyprintJson(stdout, data);
    }

    {
        // Existing formatting shall be ignored
        var data =
            \\{
            \\    "key": "value",
            \\    "key2":[1,2,
            \\3],
            \\    "key3":{},
            \\    "key4":5,
            \\    "key5":[{},{"inner  with  space":["hepp"]}]
            \\}
        ;

        try prettyprintJson(stdout, data);
    }

    {
        // Special chars in string shall not be processed
        var data =
            \\{
            \\    "key": "{[:value]}"
            \\}
        ;

        try prettyprintJson(stdout, data);
    }
}

/// Super-naive pretty-printer for XML data
/// Assumes a string of well-formed XML and attempts to print it in a human readable structure
fn prettyprintXml(writer: Writer, data: []const u8) anyerror!void {
    // For each opening element: indent
    // For each closing element: de-indent
    // TODO: Sequence of closing-tags will now be seperated by extra nl
    // TODO: Handle cdata and comments
    const State = enum {
        Outside,
        EnteredOpeningTag,
        EnteredClosingTag,
    };

    var state: State = .Outside;

    var indent_level: i64 = 0;
    var i: usize = 0;
    while (i < data.len - 1) : (i += 1) switch (data[i]) {
        '<' => {
            if (data[i + 1] == '/') {
                state = .EnteredClosingTag;
                indent_level -= 4;
                try nl(writer, indent_level);
            } else {
                state = .EnteredOpeningTag;
                try nl(writer, indent_level);
            }
            try writer.print("{c}", .{data[i]});
        },
        '>' => {
            try writer.print("{c}", .{data[i]});

            if (state == .EnteredOpeningTag) {
                if (data[i - 1] != '/' and data[i - 1] != '?') {
                    indent_level += 4;
                }
                try nl(writer, indent_level);
                state = .Outside;
            } else if (state == .EnteredClosingTag) {
                state = .Outside;
            }
        },
        '\n' => {
            continue;
        },
        ' ', '\t' => {
            // TODO: Can also skip if there are multiple spaces
            if (state == .Outside) continue;
            try writer.print("{c}", .{data[i]});
        },
        else => {
            try writer.print("{c}", .{data[i]});
        },
    };
    try writer.print("{c}", .{data[data.len - 1]});
    try writer.writeAll("\n");
}

test "pretty-print XML" {
    {
        var data =
            \\<?xml version="1.0" encoding="UTF-8"?><some><element>content</element><sibling><selfclosed />siblingcontent</sibling></some>
        ;

        // Should become:
        // <?xml version="1.0" encoding="UTF-8"?>
        // <some>
        //     <element>
        //          content
        //     </element>
        //     <sibling>
        //         <selfclosed />
        //         siblingcontent
        //     </sibling>
        // </some>

        try prettyprintXml(stdout, data);
    }
    {
        var data =
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<some>
            \\    <element>
            \\         content
            \\    </element>
            \\    <sibling>
            \\        <selfclosed />
            \\        siblingcontent
            \\    </sibling>
            \\</some>
        ;
        // Should be as it is

        try prettyprintXml(stdout, data);
    }
}

/// Returns true for any chars that are allowed for an HMTL-tag
fn is_valid_tag_char(char: u8) bool {
    return switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', ':', '-', '!' => true,
        else => false,
    };
}

/// Asssumes buf marks the start of the tag-name (i.e. after '<'), then returns a slice of the tag-name
fn get_tag_name(buf: []const u8) []const u8 {
    var i: usize = 0;
    while (i < buf.len and is_valid_tag_char(buf[i])) : (i += 1) {}
    // debug("i: {d}\n", .{i});
    return buf[0..i];
}

/// Returns true if the provided tag-name is one of the self-contained HTML-elements
fn is_html_self_closing_element(el: []const u8) bool {
    const candidate_els = [_][]const u8{ "!doctype", "input", "link", "meta", "!--" };

    for (candidate_els) |cand_el| {
        if (std.mem.eql(u8, cand_el, el)) {
            return true;
        }
    }
    return false;
}

/// Returns true for HTML-elements that allow arbitratry child-content, e.g. script and style
fn is_raw_contents_element(el: []const u8) bool {
    const candidate_els = [_][]const u8{
        "script",
        "style",
    };

    for (candidate_els) |cand_el| {
        if (std.mem.eql(u8, cand_el, el)) {
            return true;
        }
    }
    return false;
}

/// Super-naive pretty-printer for HTML data
/// Assumes a string of well-formed HTML and attempts to print it in a human readable structure
/// Your HTML is not sacred to me...
fn prettyprintHtml(writer: Writer, data: []const u8) anyerror!void {
    // Need to detect element, start, and possibly end unless self-closed.
    // start: (< + non-space) + (/> | > | space)
    // Self-closable elements: !doctype, input, link, meta
    // LE+Indent when non-self-closable
    // Existing formatting: If text between elements, trail surrounding space. If no text between elements: trim all space. All Newlines are ignored(?)
    // Now: Don't bother with unmatched tags: open-tags increases, close-tags decreases
    // Embedded data: In-file js and css: Leave as it is
    var indent_level: i64 = 0;
    var i: usize = 0;
    var current_tag: []const u8 = undefined;
    var is_close_tag: bool = false;
    var is_in_tag: bool = false;
    while (i < data.len) : (i += 1) switch (data[i]) {
        '<' => {
            is_in_tag = true;
            if (data[i + 1] == '/') {
                is_close_tag = true;
                indent_level -= 4;
                try nl(writer, indent_level);
                try writer.print("{c}", .{data[i]});
                i += 1;
            } else {
                is_close_tag = false;
            }
            current_tag = get_tag_name(data[i + 1 ..]);

            try writer.print("{c}", .{data[i]});
        },
        '>' => {
            is_in_tag = false;
            try writer.print("{c}", .{data[i]});
            if(!is_close_tag and is_raw_contents_element(current_tag)) {
                var buf: [128]u8 = undefined;
                var close_tag = try std.fmt.bufPrint(buf[0..], "</{s}", .{current_tag});
                if(std.mem.indexOf(u8, data[i..], close_tag)) |end_of_raw_area| {
                    var j: usize = 1;
                    while(j<end_of_raw_area-1) : ( j += 1 ) {
                        try writer.print("{c}", .{data[i+j]});
                    }
                    i += j-1;
                }
            }
            if (!is_html_self_closing_element(current_tag)) {
                if (!is_close_tag) indent_level += 4;
            }
            try nl(writer, indent_level);
        },
        '\n' => {
            continue;
        },
        ' ' => {
            if (!is_in_tag) continue;
            try writer.print("{c}", .{data[i]});
        },
        else => {
            try writer.print("{c}", .{data[i]});
        },
    };
    try writer.print("\n", .{});
}

test "prettyprintHtml" {
    {
        var data =
            \\<!doctype html><html dir="ltr" lang="no"><head> <meta charset="utf-8"> <title>MyTitle.com</title> <meta name="Description" content="Løsningen for deg som ønsker å varsles ved kommende problemvær slik at du kan ta bedre vare på dine utsatte eiendeler"> <meta name="viewport" content="width=device-width, initial-scale=1.0"> <meta name="theme-color" content="#16161d"> <meta name="apple-mobile-web-app-capable" content="yes"> <meta http-equiv="x-ua-compatible" content="IE=Edge"> <link rel="modulepreload" href="/build/p-64e23fb1.js"><link rel="modulepreload" href="/build/p-15a7289e.js"><link rel="modulepreload" href="/build/p-9b6a9315.js"><link rel="modulepreload" href="/build/p-ee911213.js"><script type="module" src="/build/p-64e23fb1.js" data-stencil data-resources-url="/build/" data-stencil-namespace="app"></script> <script nomodule="" src="/build/app.js" data-stencil></script> <style>@font-face{font-family:Roboto-Thin;src:url(/assets/fonts/Roboto-Thin.ttf)}@font-face{font-family:Roboto-Light;src:url(/assets/fonts/Roboto-Light.ttf)}@font-face{font-family:Roboto-Regular;src:url(/assets/fonts/Roboto-Regular.ttf)}body{margin:0px;padding:0px;font-family:Roboto-Light;line-height:1.5}header{}</style> <script src="https://unpkg.com/leaflet@1.7.1/dist/leaflet.js"></script> <link rel="stylesheet" href="https://unpkg.com/leaflet@1.7.1/dist/leaflet.css"> <link rel="apple-touch-icon" href="/assets/icon/icon.png"> <link rel="icon" type="image/x-icon" href="/assets/icon/favicon.png"> <link rel="manifest" href="/manifest.json"> </head> <body id="top"> <app-root></app-root> </body></html>
        ;

        try prettyprintHtml(stdout, data);
    }

    // Inline CSS
    {
        var data =
            \\<!doctype html>
            \\<html dir="ltr" lang="no">
            \\<head>
            \\    <meta charset="utf-8">
            \\    <title>Some page</title>
            \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\    <link rel="modulepreload" href="/build/p-64e23fb1.js">
            \\    <script type="module" src="/build/p-64e23fb1.js" data-stencil data-resources-url="/build/"
            \\        data-stencil-namespace="app"></script>
            \\    <script nomodule="" src="/build/app.js" data-stencil></script>
            \\    <style>
            \\        @font-face {
            \\            font-family: Roboto-Thin;
            \\            src: url(/assets/fonts/Roboto-Thin.ttf)
            \\        }
            \\
            \\        body {
            \\            margin: 0px;
            \\            padding: 0px;
            \\        }
            \\        /* comment */
            \\        parent>child {}
            \\    </style>
            \\    <script src="https://some.service/app.js"></script>
            \\    <link rel="stylesheet" href="https://some.service/app.css">
            \\    <link rel="manifest" href="/manifest.json">
            \\</head>
            \\
            \\<body id="top">
            \\    <!-- Comment -->
            \\    <app-root></app-root>
            \\</body>
            \\
            \\</html>
        ;

        try prettyprintHtml(stdout, data);
    }
}
