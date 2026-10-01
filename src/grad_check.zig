const std = @import("std");
const conversion = @import("conversion.zig");
const tvg_parsing = @import("tinyvg/parsing.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const svg =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><defs><linearGradient id="a" x1="0" y1="0" x2="24" y2="24" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#7c4dff"/><stop offset="1" stop-color="#ef5350"/></linearGradient></defs><path fill="url(#a)" d="M0 0 L24 0 L24 24 Z"/></svg>
    ;
    const bytes = try conversion.tvg_from_svg(gpa, svg, .{});
    defer gpa.free(bytes);
    std.debug.print("converted {d} bytes\n", .{bytes.len});
    var reader: std.Io.Reader = .fixed(bytes);
    var parser = try tvg_parsing.Parser().init(gpa, &reader);
    defer parser.deinit();
    var saw_linear = false;
    while (try parser.next()) |cmd| {
        switch (cmd) {
            .fill_path => |fp| {
                if (fp.style == .linear) saw_linear = true;
            },
            else => {},
        }
    }
    std.debug.print("saw_linear={}\n", .{saw_linear});
}
