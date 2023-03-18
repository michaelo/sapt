/// Module with functions to simple and efficiently provide a pretty-ish view of certain data types: JSON, XML and HTML.
/// This is intentionally not focused on perfect formatting, and will not employ full tokenizing and such techniques to achieve this.
/// This is simply intended as a quick way to make the content returned somewhat more easy to inspect.
/// So, DISCLAIMER: Don't uncritically rely on the formatted output. If in doubt - check the raw response.
/// This is also why formatted output should not be on by default.
///
/// TOOD: The parsers/printers can be cleaned up quite a bit.
/// TBD: Support basic syntax highlighting as well?
/// TBD: Can add basic CSS and JS-formatters as well to support in-filed <style> and <script>
const std = @import("std");
const testing = std.testing;
const debug = std.debug.print;
const Writer = std.fs.File.Writer;

const INDENTATION_STEP = 4;

/// Module entry point. Takes a MIME-type and returns a function which takes a std.fs.File.Writer and a u8-slice to
/// format and write to that Writer.
/// The pretty-printers support writing partial chunks.
pub fn getPrettyPrinterByContentType(content_type: []const u8) fn (Writer, []const u8) anyerror!void {
    if (isContentTypeJson(content_type)) return prettyprintJson;
    if (isContentTypeXml(content_type)) return prettyprintXml;
    if (isContentTypeHtml(content_type)) return prettyprintHtml;
    return passthrough;
}

test "getPrettyPrinterByContentType" {
    try testing.expectEqual(prettyprintJson, getPrettyPrinterByContentType("application/json"));
    try testing.expectEqual(prettyprintHtml, getPrettyPrinterByContentType("text/html"));
    try testing.expectEqual(prettyprintXml, getPrettyPrinterByContentType("text/xml"));
    try testing.expectEqual(passthrough, getPrettyPrinterByContentType("something/else"));
}

/// Writes a newline + a given number of spaces to ensure indendation
fn nl(writer: Writer, num: i64) !void {
    var i = num;
    // TBD: Support CRLF for Win?
    try writer.print("\n", .{});
    while (i > 0) : (i -= 1) try writer.print(" ", .{});
}

fn isContentType(content_type: []const u8, types_chunks: []const []const u8) bool {
    for (types_chunks) |end| {
        if (std.mem.indexOf(u8, content_type, end) != null) return true;
    }
    return false;
}

fn isContentTypeJson(content_type: []const u8) bool {
    const types_chunk = [_][]const u8{"/json"};

    return isContentType(content_type, types_chunk[0..]);
}

fn isContentTypeXml(content_type: []const u8) bool {
    const types_chunk = [_][]const u8{ "/xml", "+xml" };

    return isContentType(content_type, types_chunk[0..]);
}

fn isContentTypeHtml(content_type: []const u8) bool {
    const types_chunk = [_][]const u8{"/html"};

    return isContentType(content_type, types_chunk[0..]);
}

test "isContentTypeJson" {
    try testing.expect(isContentTypeJson("application/json"));
    try testing.expect(!isContentTypeJson("text/html"));
    try testing.expect(!isContentTypeJson("text/xml"));
}

test "isContentTypeHtml" {
    try testing.expect(isContentTypeHtml("text/html"));
    try testing.expect(!isContentTypeHtml("application/json"));
    try testing.expect(!isContentTypeHtml("text/xml"));
    try testing.expect(!isContentTypeHtml("application/xml"));
    try testing.expect(!isContentTypeHtml("application/xhtml+xml"));
}

test "isContentTypeXml" {
    try testing.expect(isContentTypeXml("text/xml"));
    try testing.expect(isContentTypeXml("application/xml"));
    try testing.expect(isContentTypeXml("application/xhtml+xml"));
    try testing.expect(!isContentTypeXml("application/json"));
    try testing.expect(!isContentTypeXml("text/html"));
}

/// Simple passes through with not formatting actions
fn passthrough(writer: Writer, data: []const u8) anyerror!void {
    try writer.writeAll(data);
}

/// Super-naive pretty-printer for JSON data
/// Assumes a string of well-formed JSON and attempts to print it in a human readable structure
/// TODO: Rewrite to parse as (SIMD-)vectors? We then need to check character-groups for the characters we switch on
///       Not important for this project, might split out to see what can be done.
fn prettyprintJson(writer: Writer, data: []const u8) anyerror!void {
    // Assume well-structured json - do an as-simple-as-possible pretty-print without semantically parsing
    // For each new line, start with padding the indent_level

    var indent_level: i64 = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        var char = data[i];
        switch (char) {
            '{' => {
                indent_level += INDENTATION_STEP;
                try writer.print("{c}", .{char});
                try nl(writer, indent_level);
            },
            '}' => {
                indent_level -= INDENTATION_STEP;
                try nl(writer, indent_level);
                try writer.print("{c}", .{char});
            },
            '[' => {
                indent_level += INDENTATION_STEP;
                try writer.print("{c}", .{char});
                try nl(writer, indent_level);
            },
            ']' => {
                indent_level -= INDENTATION_STEP;
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
                // Assumes the first " we meet isn't an escaped one
                // Dump all until first non-escaped "
                try writer.print("{c}", .{data[i]});
                i += 1;
                while (!(data[i] == '"' and data[i - 1] != '\\')) : (i += 1) {
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

test "prettyprintJson" {
    const stdout = std.io.getStdOut().writer();
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
            \\    "key5":[{},{"inner  with  space":["hepp"]}]
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
    // Need to detect element, start, and possibly end unless self-closed.
    // start: (< + non-space) + (/> | > | space)
    // Self-closable elements: !doctype, input, link, meta
    // LE+Indent when non-self-closable
    // Existing formatting: If text between elements, trail surrounding space. If no text between elements: trim all space. All Newlines are ignored(?)
    // Now: Don't bother with unmatched tags: open-tags increases, close-tags decreases
    // Embedded data: In-file js and css: Leave as it is
    // TODO: This can be way more efficient with smarter parsing (e.g. not go char-by-char) - but will do for now as the intended data sizes are relatively small and this is not core functionality
    var indent_level: i64 = 0;
    var i: usize = 0;
    var current_tag: []const u8 = undefined;
    var is_close_tag: bool = false;
    var is_in_tag: bool = false;
    var is_in_text: bool = false; // Keep whitespace etc while inside text-segment
    while (i < data.len - 1) : (i += 1) switch (data[i]) {
        // Start of tag, can be either opening or closing tag
        '<' => {
            is_in_text = false;
            is_in_tag = true;
            // If close-tag
            if (data[i + 1] == '/') {
                is_close_tag = true;
                indent_level -= INDENTATION_STEP;
                try nl(writer, indent_level);
                try writer.print("{c}", .{data[i]});
                try writer.print("{c}", .{data[i + 1]});
                i += 1;
            } else {
                is_close_tag = false;
                current_tag = getTagName(data[i + 1 ..]);
                if (std.mem.startsWith(u8, current_tag, "!--")) try nl(writer, indent_level);
                try writer.print("{c}", .{data[i]});
            }
        },
        // End of tag, can be either opening or closing tag
        '>' => {
            is_in_tag = false;
            try writer.print("{c}", .{data[i]});
            if (!is_close_tag and isHtmlOrXmlRawContentsElement(current_tag)) {
                // Find closing-tag of raw-contents-element
                var buf: [128]u8 = undefined;
                var close_tag = try std.fmt.bufPrint(buf[0..], "</{s}", .{current_tag});

                if (std.mem.indexOf(u8, data[i..], close_tag)) |end_of_raw_area_idx| {
                    var j: usize = 1;
                    while (j < end_of_raw_area_idx - 1) : (j += 1) {
                        try writer.print("{c}", .{data[i + j]});
                    }
                    i += j - 1;
                }
            }

            // Only increase indentation for open-tags
            if (!is_close_tag and data[i - 1] != '/' and !isHtmlOrXmlSelfclosingElement(current_tag)) {
                indent_level += INDENTATION_STEP;
            }

            try nl(writer, indent_level);
        },
        // Ignore all newlines
        '\n' => {
            if (!is_in_tag or !isHtmlOrXmlRawContentsElement(current_tag)) continue;
            try writer.print("{c}", .{data[i]});
        },
        // Ignore whitespace between elements, and between elements and text-chunks
        ' ', '\t' => {
            if (!is_in_tag and !is_in_text) continue;
            try writer.print("{c}", .{data[i]});
        },
        // All other characters
        else => {
            if (!is_in_tag) is_in_text = true;
            try writer.print("{c}", .{data[i]});
        },
    };
    try writer.print("{c}", .{data[i]});
    try writer.print("\n", .{});
}

test "prettyprintXml" {
    const stdout = std.io.getStdOut().writer();
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
            \\        <!-- Comment -->
            \\        <![CDATA[
            \\        characters with markup
            \\        ]]>
            \\    </sibling>
            \\</some>
        ;
        // Should be as it is

        try prettyprintXml(stdout, data);
    }
}

/// Returns true for any chars that are allowed for an HTML or XML-tag
fn isValidTagChar(char: u8) bool {
    return switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', ':', '-', '!', '?', '[' => true,
        else => false,
    };
}

/// Asssumes buf marks the start of the tag-name (i.e. after '<'), then returns a slice of the tag-name
fn getTagName(buf: []const u8) []const u8 {
    var i: usize = 0;
    while (i < buf.len and isValidTagChar(buf[i])) : (i += 1) {}
    return buf[0..i];
}

/// Returns true if the provided tag-name is one of the self-contained HTML-elements
fn isHtmlOrXmlSelfclosingElement(el: []const u8) bool {
    // Regular elements whose names are separated by e.g. space
    {
        const candidate_els = [_][]const u8{ "!doctype", "input", "link", "img", "meta", "br", "?xml" };

        for (candidate_els) |cand_el| {
            if (std.mem.eql(u8, el, cand_el)) {
                return true;
            }
        }
    }

    // Elements that might have content directly after the name/indicator
    {
        const candidate_els = [_][]const u8{ "!--", "![CDATA[" };

        for (candidate_els) |cand_el| {
            if (std.mem.startsWith(u8, el, cand_el)) {
                return true;
            }
        }
    }
    return false;
}

/// Returns true for HTML-elements that allow arbitratry child-content, e.g. script and style
fn isHtmlOrXmlRawContentsElement(el: []const u8) bool {
    const candidate_els = [_][]const u8{ "script", "style", "![CDATA[" };

    for (candidate_els) |cand_el| {
        if (std.mem.startsWith(u8, cand_el, el)) {
            return true;
        }
    }
    return false;
}

/// Super-naive pretty-printer for HTML data
/// Assumes a string of well-formed HTML and attempts to print it in a human readable structure
/// Your HTML is not sacred to me...
const prettyprintHtml = prettyprintXml;

test "prettyprintHtml" {
    const stdout = std.io.getStdOut().writer();
    {
        var data =
            \\<!doctype html><html dir="ltr" lang="no"><head> <meta charset="utf-8"> <title>MyTitle.com</title> <meta name="Description" content="Løsningen for deg som ønsker å varsles ved kommende problemvær slik at du kan ta bedre vare på dine utsatte eiendeler"> <meta name="viewport" content="width=device-width, initial-scale=1.0"> <meta name="theme-color" content="#16161d"> <meta name="apple-mobile-web-app-capable" content="yes"> <meta http-equiv="x-ua-compatible" content="IE=Edge"> <link rel="modulepreload" href="/build/p-64e23fb1.js"><link rel="modulepreload" href="/build/p-15a7289e.js"><link rel="modulepreload" href="/build/p-9b6a9315.js"><link rel="modulepreload" href="/build/p-ee911213.js"><script type="module" src="/build/p-64e23fb1.js" data-stencil data-resources-url="/build/" data-stencil-namespace="app"></script> <script nomodule="" src="/build/app.js" data-stencil></script> <style>@font-face{font-family:Roboto-Thin;src:url(/assets/fonts/Roboto-Thin.ttf)}@font-face{font-family:Roboto-Light;src:url(/assets/fonts/Roboto-Light.ttf)}@font-face{font-family:Roboto-Regular;src:url(/assets/fonts/Roboto-Regular.ttf)}body{margin:0px;padding:0px;font-family:Roboto-Light;line-height:1.5}header{}</style> <script src="https://unpkg.com/leaflet@1.7.1/dist/leaflet.js"></script> <link rel="stylesheet" href="https://unpkg.com/leaflet@1.7.1/dist/leaflet.css"> <link rel="apple-touch-icon" href="/assets/icon/icon.png"> <link rel="icon" type="image/x-icon" href="/assets/icon/favicon.png"> <link rel="manifest" href="/manifest.json"> </head> <body id="top"> <app-root></app-root> </body></html>
        ;

        try prettyprintHtml(stdout, data);
    }

    // With inline CSS and inline JS
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
            \\    <script>
            \\      function something_formatted() {
            \\          console.log("Woop");
            \\      }
            \\      
            \\      function something_unformatted() { console.log("Woop"); }
            \\    </script>
            \\    <script src="https://some.service/app.js"></script>
            \\    <link rel="stylesheet" href="https://some.service/app.css">
            \\    <link rel="manifest" href="/manifest.json">
            \\</head>
            \\
            \\<body id="top">
            \\    <app-root></app-root>
            \\    <!-- Comment -->
            \\    <p>Some content here</p>
            \\</body>
            \\
            \\</html>
        ;

        try prettyprintXml(stdout, data);
    }
}
