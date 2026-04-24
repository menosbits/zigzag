const std = @import("std");
const testing = std.testing;
const zz = @import("zigzag");

test "Markdown renders headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = zz.Markdown.init();

    const output = try md.render(arena.allocator(), "# Hello");
    try testing.expect(output.len > 0);
    // Should contain "Hello" somewhere in the styled output
    try testing.expect(std.mem.indexOf(u8, output, "Hello") != null);
}

test "Markdown renders bold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = zz.Markdown.init();

    const output = try md.render(arena.allocator(), "This is **bold** text");
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.indexOf(u8, output, "bold") != null);
}

test "Markdown renders inline code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = zz.Markdown.init();

    const output = try md.render(arena.allocator(), "Use `hello` function");
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.indexOf(u8, output, "hello") != null);
}

test "Markdown renders unordered list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = zz.Markdown.init();

    const output = try md.render(arena.allocator(), "- Item one\n- Item two");
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.indexOf(u8, output, "Item one") != null);
}

test "Markdown renders blockquote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = zz.Markdown.init();

    const output = try md.render(arena.allocator(), "> This is a quote");
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.indexOf(u8, output, "quote") != null);
}

test "Markdown renders code block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = zz.Markdown.init();

    const output = try md.render(arena.allocator(), "```\nconst x = 1;\n```");
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.indexOf(u8, output, "const x = 1;") != null);
}

test "Markdown renders horizontal rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = zz.Markdown.init();

    const output = try md.render(arena.allocator(), "---");
    try testing.expect(output.len > 0);
}

test "Markdown renders links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = zz.Markdown.init();

    const output = try md.render(arena.allocator(), "Visit [ZigZag](https://github.com)");
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.indexOf(u8, output, "ZigZag") != null);
}

test "Markdown empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = zz.Markdown.init();

    const output = try md.render(arena.allocator(), "");
    try testing.expect(output.len == 0);
}

test "Markdown mixed content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const md = zz.Markdown.init();

    const input =
        \\# Title
        \\
        \\Some **bold** and *italic* text.
        \\
        \\- List item
        \\
        \\> Quote
    ;

    const output = try md.render(arena.allocator(), input);
    try testing.expect(output.len > 0);
}
