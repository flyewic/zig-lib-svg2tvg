const std = @import("std");
const assert = std.debug.assert;
const expect = std.debug.expect;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const math = std.math;
const ut = @import("util.zig");
const utils = ut.utils;
const ColorHash = ut.ColorHash;
const Stack = ut.Stack;
const NodeMaker = ut.NodeMaker;
const ColMap = ut.ColMap;
const svg_ut = @import("svg-util.zig");
const SvgColor = svg_ut.SvgColor;
const SvgColorAttribute = svg_ut.SvgColorAttribute;

const xml = @import("xml");

const tinyvg2 = @import("tinyvg/tinyvg.zig");
pub const tvg = tinyvg2;

pub const Color = tvg.Color;
const Path = tvg.Path;
const Segment = Path.Segment;
const Node = Path.Node;
const NodeData = Path.Node.NodeData;
const Point = tvg.Point;
const Scale = tvg.Scale;
const Range = tvg.Range;
const Style = tvg.Style;

const WidthHeight = struct {
    w: ?f32 = null,
    h: ?f32 = null,
};
const ViewBox = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: ?f32 = null,
    h: ?f32 = null,
    fn transform(
        self: *const @This(),
        width: f32,
        height: f32,
        point: Point,
    ) Point {
        assert(width != 0);
        assert(height != 0);
        assert(self.w.? != 0);
        assert(self.h.? != 0);
        return Point{
            .x = (point.x - self.x) * (width / self.w.?),
            .y = (point.y - self.y) * (height / self.h.?),
        };
    }
};

const InheritableProperties = struct {
    fill: ?SvgColor = .{ .col = .{
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 1,
    } }, // Fill color
    stroke: ?SvgColor = null, // Stroke (outline) color
    color: ?SvgColor = null, // Used as base color (currentColor, filters, etc.)
    @"fill-opacity": ?f32 = null, // Opacity of the fill
    @"stroke-opacity": ?f32 = null, // Stroke opacity
    @"stroke-width": ?f32 = null, // Stroke thickness
    // @"stroke-dasharray": ? = null, // Dash pattern of the stroke
    // @"stroke-dashoffset": ? = null, // Offset into the dash pattern
    // @"stroke-linecap": ?C = null, // Shape of stroke ends (butt, round, square)
    // @"stroke-linejoin": ? = null, // Corner rendering (miter, round, bevel)
    // @"stroke-miterlimit": ? = null, // Miter limit for sharp corners
    opacity: ?f32 = null, // Overall opacity (applies to the whole element)
    // visibility: ?bool = null, // Whether element is visible (visible, hidden)
    // display: ?SvgColor = null, // Whether element is rendered (inline, none)
    // @"font-*": ?SvgColor = null, // If used in text elements
    // direction: ?SvgColor = null, // Text and layout direction (e.g. ltr, rtl)
    // @"text-anchor": ?SvgColor = null, // Text alignment
    // @"writing-mode": ?SvgColor = null, // Vertical/horizontal text flow
    // @"clip-path": ?SvgColor = null, // Clipping region
    // mask: ?SvgColor = null, // Mask to apply to element
    // filter: ?SvgColor = null, // Filter effects (blur, drop shadow, etc.)
    pub fn override(self: *const InheritableProperties, over: InheritableProperties) InheritableProperties {
        var ret = self.*;
        inline for (@typeInfo(InheritableProperties).@"struct".fields) |f| {
            if (@field(over, f.name)) |fval| {
                @field(ret, f.name) = fval;
            }
        }
        return ret;
    }
    pub fn override_from(self: *@This(), t: anytype) void {
        const T = @TypeOf(t);
        inline for (@typeInfo(InheritableProperties).@"struct".fields) |f| {
            if (comptime utils.has_field(T, f.name)) {
                // @compileLog(T, f.name);
                if (comptime f.type == @TypeOf(@field(t, f.name))) {
                    if (@field(t, f.name)) |fval| {
                        @field(self, f.name) = fval;
                    }
                }
            }
        }
    }
    pub fn resolve_color_property(stack: *const Stack(InheritableProperties), comptime name: []const u8) !?Color {
        var it = stack.rev_iter();
        while (it.next()) |top| {
            const mcol: ?SvgColor = @field(top, name);
            if (mcol == null) return null;
            if (mcol.? == .col) return mcol.?.col;
            const att: SvgColorAttribute = mcol.?.att;
            switch (att) {
                .none => return null,
                .inherit => continue,
                .currentColor => continue,
            }
        }
        @panic("bottom of stack should have color");
    }

    /// Resolved paint for a `fill`/`stroke` property: a flat color, a gradient
    /// paint-server reference (`url(#id)`), or none. Unlike
    /// `resolve_color_property` this preserves a gradient reference instead of
    /// treating it as opaque/black.
    pub const Paint = union(enum) {
        color: Color,
        gradient: []const u8,
        none,
    };

    pub fn resolve_paint_property(stack: *const Stack(InheritableProperties), comptime name: []const u8) !Paint {
        var it = stack.rev_iter();
        while (it.next()) |top| {
            const mcol: ?SvgColor = @field(top, name);
            if (mcol == null) return .none;
            switch (mcol.?) {
                .col => |c| return .{ .color = c },
                .url => |id| return .{ .gradient = id },
                .att => |att| switch (att) {
                    .none => return .none,
                    .inherit => continue,
                    .currentColor => continue,
                },
            }
        }
        @panic("bottom of stack should have color");
    }
};

const SvgTag = enum(u8) {
    svg,
    rect,
    circle,
    ellipse,
    line,
    polyline,
    polygon,
    path,
    // text,
    // textPath,
    // tref,
    // tspan,
    // a, //link
    // image,
    // marker,
};

/// A parsed paint server (`<linearGradient>` / `<radialGradient>`). Stops are
/// kept as an ordered list of (offset, color); TinyVG only holds two colors per
/// gradient, so the converter samples the first and last stop.
const GradientDef = struct {
    const Kind = enum { linear, radial };

    kind: Kind = .linear,
    /// Linear: x1,y1 -> x2,y2. Radial: cx,cy (focal fx,fy ignored), r.
    x1: f32 = 0,
    y1: f32 = 0,
    x2: f32 = 1,
    y2: f32 = 0,
    cx: f32 = 0.5,
    cy: f32 = 0.5,
    r: f32 = 0.5,
    fx: f32 = 0.5,
    fy: f32 = 0.5,
    /// objectBoundingBox (default) vs userSpaceOnUse.
    user_space: bool = false,
    /// Accumulated `gradientTransform` (a=b=c=d=e=f, column-major 2x3).
    tx: f32 = 1,
    ty: f32 = 0,
    tz: f32 = 0,
    tw: f32 = 1,
    te: f32 = 0,
    tf: f32 = 0,
    /// `xlink:href`/`href` to another gradient whose missing attrs/stops inherit.
    href: ?[]const u8 = null,
    stops: std.ArrayListUnmanaged(Stop) = .empty,

    const Stop = struct { offset: f32, color: Color };

    fn deinit(self: *GradientDef, alloc: Allocator) void {
        self.stops.deinit(alloc);
    }

    fn applyTransform(self: GradientDef, p: Point) Point {
        return .{
            .x = self.tx * p.x + self.tz * p.y + self.te,
            .y = self.ty * p.x + self.tw * p.y + self.tf,
        };
    }
};

/// All paint servers defined in a document, keyed by fragment id.
const GradientMap = std.StringHashMapUnmanaged(GradientDef);

pub const Svg = struct {
    pub const xmlns = "http://www.w3.org/2000/svg";
    x: f32 = 0,
    y: f32 = 0,
    width: ?f32 = null, // default is auto ?! wtf is auto
    height: ?f32 = null, // default is auto ?! wtf is auto
    viewBox: ViewBox = ViewBox{},
    // preserveAspectRatio="How the svg fragment is deformed if it is displayed with a different aspect ratio". Can be none| xMinYMin| xMidYMin| xMaxYMin| xMinYMid| xMidYMid| xMaxYMid| xMinYMax| xMidYMax| xMaxYMax. Default is xMidYMid
    fill: ?SvgColor = null,
    @"fill-opacity": ?f32 = null, // between 0 and 1
    stroke: ?SvgColor = null,
    @"stroke-width": ?f32 = null,
    @"stroke-opacity": ?f32 = null, // between 0 and 1
    pub fn parse(
        self: *@This(),
        alloc: Allocator,
        att: []const []const u8,
        val: []const []const u8,
    ) !void {
        const Def = struct {
            pub const width: ?f32 = undefined;
            pub const height: ?f32 = undefined;
            pub const fill: ?SvgColor = undefined;
            pub const @"fill-opacity": ?f32 = undefined;
            pub const stroke: ?SvgColor = undefined;
            pub const @"stroke-width": ?f32 = undefined;
            pub const @"stroke-opacity": ?f32 = undefined;
        };
        for (att, val) |a, v| {
            try utils.auto_parse_def(@This(), self, Def, a, v);
            if (try utils.parsePointList(alloc, "viewBox", a, v)) |res| {
                if (res.items.len != 2) return error.ViewBoxMisformed;
                self.viewBox.x = res.items[0].x;
                self.viewBox.y = res.items[0].y;
                self.viewBox.w = res.items[1].x;
                self.viewBox.h = res.items[1].y;
            }
        }
    }
    pub fn check(self: *@This()) !void {
        if (self.width == null) self.width = self.viewBox.w;
        if (self.height == null) self.height = self.viewBox.h;
        if (self.viewBox.h == null or self.viewBox.w == null) {
            self.viewBox.w = self.width;
            self.viewBox.h = self.height;
        }
        if (self.width == null or self.height == null) return error.NoWidthHeightDefined;
    }
    pub fn transform(self: *const @This(), pp: Point) Point {
        const p = Point{
            .x = @floatCast(pp.x),
            .y = @floatCast(pp.y),
        };
        const ret = self.viewBox.transform(self.width.?, self.height.?, p);
        assert(math.isNormal(ret.x) or ret.x == 0);
        assert(math.isNormal(ret.y) or ret.y == 0);
        return ret;
    }
    // pub fn point_from(self: *const @This(), coord: svg_parsing.CoordinatePair) Point {
    //     const p = Point{
    //         .x = @floatCast(coord.coordinates[0].number.value),
    //         .y = @floatCast(coord.coordinates[1].number.value),
    //     };
    //     return self.viewBox.transform(@floatFromInt(self.width.?), @floatFromInt(self.height.?), p);
    // }
};
pub const ColorProperties: []const []const u8 = &.{
    "fill",
    "stroke",
};
pub const f32Properties = struct {
    // not supported dor now!
    pub const Opacity: []const []const u8 = &.{
        "stroke-opacity",
        "fill-opacity",
        "opacity",
    };
};
const Rect = struct {
    width: ?f32 = null, //the width of the rectangle. Required.
    height: ?f32 = null, //the height of the rectangle Required.
    x: f32 = 0, //the x-position for the top-left corner of the rectangle
    y: f32 = 0, //the y-position for the top-left corner of the rectangle
    rx: f32 = 0, //The x radius of the corners of the rectangle (used to round the corners). Default is 0
    ry: f32 = 0, //The y radius of the corners of the rectangle (used to round the corners). Default is 0
    // pathLength = "the total length for the rectangle's perimeter",
    fill: ?SvgColor = null,
    @"fill-opacity": ?f32 = null, // between 0 and 1
    stroke: ?SvgColor = null,
    @"stroke-width": ?f32 = null,
    @"stroke-opacity": ?f32 = null, // between 0 and 1
    pub fn parse(
        self: *@This(),
        maker: *NodeMaker,
        att: []const []const u8,
        val: []const []const u8,
    ) !void {
        const Def = struct {
            pub const width: ?f32 = undefined;
            pub const height: ?f32 = undefined;
            pub const x: f32 = undefined;
            pub const y: f32 = undefined;
            pub const rx: f32 = undefined;
            pub const ry: f32 = undefined;
            pub const fill: ?SvgColor = undefined;
            pub const @"fill-opacity": ?f32 = undefined;
            pub const stroke: ?SvgColor = undefined;
            pub const @"stroke-width": ?f32 = undefined;
            pub const @"stroke-opacity": ?f32 = undefined;
        };
        for (att, val) |a, v| {
            try utils.auto_parse_def(@This(), self, Def, a, v);
        }
        if (self.width == null or self.height == null) return error.RectWithoutDimensions;
        const yline_len = @max(0, self.height.? - self.ry * 2);
        const xline_len = @max(0, self.width.? - self.rx * 2);
        var p = Point{
            .x = self.x + self.rx,
            .y = self.y,
        };
        try maker.move(p, false);
        p.x += xline_len;
        try maker.line(p, false);
        p.x += self.rx;
        p.y += self.ry;
        try maker.elliptical_arc(self.rx, self.ry, 0, false, true, p, false);
        p.y += yline_len;
        try maker.line(p, false);
        p.x += -self.rx;
        p.y += self.ry;
        try maker.elliptical_arc(self.rx, self.ry, 0, false, true, p, false);
        p.x += -xline_len;
        try maker.line(p, false);
        p.x += -self.rx;
        p.y += -self.ry;
        try maker.elliptical_arc(self.rx, self.ry, 0, false, true, p, false);
        p.y += -yline_len;
        try maker.line(p, false);
        p.x += self.rx;
        p.y += -self.ry;
        try maker.elliptical_arc(self.rx, self.ry, 0, false, true, p, false);
        try maker.flush();
    }
};
const Circle = struct {
    r: ?f32 = null, //The radius of the circle. Required
    cx: f32 = 0, //the x-axis center of the circle
    cy: f32 = 0, //the y-axis center of the circle
    fill: ?SvgColor = null,
    @"fill-opacity": ?f32 = null, // between 0 and 1
    stroke: ?SvgColor = null,
    @"stroke-width": ?f32 = null,
    @"stroke-opacity": ?f32 = null, // between 0 and 1
    pub fn parse(
        self: *@This(),
        maker: *NodeMaker,
        att: []const []const u8,
        val: []const []const u8,
    ) !void {
        const Def = struct {
            pub const r: ?f32 = undefined;
            pub const cx: f32 = undefined;
            pub const cy: f32 = undefined;
            pub const fill: ?SvgColor = undefined;
            pub const @"fill-opacity": ?f32 = undefined;
            pub const stroke: ?SvgColor = undefined;
            pub const @"stroke-width": ?f32 = undefined;
            pub const @"stroke-opacity": ?f32 = undefined;
        };
        for (att, val) |a, v| {
            try utils.auto_parse_def(@This(), self, Def, a, v);
        }
        const r = self.r orelse return error.NoRadius;

        try maker.move(.{ .x = self.cx - r, .y = self.cy }, false);
        try maker.circular_arc(r, true, false, .{ .x = self.cx + r, .y = self.cy }, false);
        try maker.circular_arc(r, true, false, .{ .x = self.cx - r, .y = self.cy }, false);
        try maker.flush();
    }
};
pub const default = struct {
    pub const stroke_width: f32 = 2;
    pub const stroke_opacity: f32 = 1; // between 0 and 1
    pub const fill_opacity: f32 = 1; // between 0 and 1
    pub fn or_stroke_width(stroke: ?f32) f32 {
        return stroke orelse stroke_width;
    }
};

const Ellipse = struct {
    rx: ?f32 = null, //the x radius of the ellipse. Required.
    ry: ?f32 = null, //the y radius of the ellipse. Required.
    cx: f32 = 0, //the x-axis center of the ellipse
    cy: f32 = 0, //the y-axis center of the ellipse
    fill: ?SvgColor = null,
    @"fill-opacity": ?f32 = null, // between 0 and 1
    stroke: ?SvgColor = null,
    @"stroke-width": ?f32 = null,
    @"stroke-opacity": ?f32 = null, // between 0 and 1
    pub fn parse(
        self: *@This(),
        maker: *NodeMaker,
        att: []const []const u8,
        val: []const []const u8,
    ) !void {
        const Def = struct {
            pub const rx: ?f32 = undefined;
            pub const ry: ?f32 = undefined;
            pub const cx: f32 = undefined;
            pub const cy: f32 = undefined;
            pub const fill: ?SvgColor = undefined;
            pub const @"fill-opacity": ?f32 = undefined;
            pub const stroke: ?SvgColor = undefined;
            pub const @"stroke-width": ?f32 = undefined;
            pub const @"stroke-opacity": ?f32 = undefined;
        };
        for (att, val) |a, v| {
            try utils.auto_parse_def(@This(), self, Def, a, v);
        }
        const rrx = self.rx orelse return error.NoRadius;
        const rry = self.ry orelse return error.NoRadius;

        try maker.move(.{ .x = self.cx - rrx, .y = self.cy }, false);
        try maker.elliptical_arc(rrx, rry, 0, false, false, .{ .x = self.cx + rrx, .y = self.cy }, false);
        try maker.elliptical_arc(rrx, rry, 0, false, false, .{ .x = self.cx - rrx, .y = self.cy }, false);
        try maker.flush();
    }
};
const Line = struct {
    x1: ?f32 = null, //"The start of the line on the x-axis"
    y1: ?f32 = null, //"The start of the line on the y-axis"
    x2: ?f32 = null, //"The end of the line on the x-axis"
    y2: ?f32 = null, //"The end of the line on the y-axis"
    stroke: ?SvgColor = null,
    @"stroke-width": ?f32 = null,
    @"stroke-opacity": ?f32 = null, // between 0 and 1
    pub fn parse(
        self: *@This(),
        maker: *NodeMaker,
        att: []const []const u8,
        val: []const []const u8,
    ) !void {
        const Def = struct {
            pub const x1: ?f32 = undefined;
            pub const y1: ?f32 = undefined;
            pub const x2: ?f32 = undefined;
            pub const y2: ?f32 = undefined;
            pub const stroke: ?SvgColor = undefined;
            pub const @"stroke-width": ?f32 = undefined;
            pub const @"stroke-opacity": ?f32 = undefined;
        };
        for (att, val) |a, v| {
            try utils.auto_parse_def(@This(), self, Def, a, v);
        }
        const ax = self.x1 orelse return error.MissingLineParameter;
        const ay = self.y1 orelse return error.MissingLineParameter;
        const bx = self.x2 orelse return error.MissingLineParameter;
        const by = self.y2 orelse return error.MissingLineParameter;
        const p1 = Point{
            .x = ax,
            .y = ay,
        };
        const p2 = Point{
            .x = bx,
            .y = by,
        };
        try maker.move(p1, false);
        try maker.line(p2, false);
        try maker.flush();
    }
};
// Defines any shape that consists of only straight lines. The shape is open
const PolyLine = struct {
    points: []const Point = &.{}, //The list of points of the polygon. Each point must contain an x coordinate and a y coordinate. Required.
    fill: ?SvgColor = null,
    @"fill-opacity": ?f32 = null, // between 0 and 1
    stroke: ?SvgColor = null,
    @"stroke-width": ?f32 = null,
    @"stroke-opacity": ?f32 = null, // between 0 and 1

    pub fn parse(
        self: *@This(),
        maker: *NodeMaker,
        alloc: Allocator,
        att: []const []const u8,
        val: []const []const u8,
    ) !void {
        const Def = struct {
            pub const fill: ?SvgColor = undefined;
            pub const @"fill-opacity": ?f32 = undefined;
            pub const stroke: ?SvgColor = undefined;
            pub const @"stroke-width": ?f32 = undefined;
            pub const @"stroke-opacity": ?f32 = undefined;
        };
        for (att, val) |a, v| {
            try utils.auto_parse_def(@This(), self, Def, a, v);
            if (try utils.parsePointList(alloc, "points", a, v)) |res| {
                self.points = res.items;
            }
        }
        for (self.points, 0..) |p, i| {
            if (i == 0) {
                try maker.move(.{ .x = p.x, .y = p.y }, false);
            } else {
                try maker.line(.{ .x = p.x, .y = p.y }, false);
            }
        }
        try maker.flush();
    }
};
// Creates a graphic that contains at least three sides. Polygons are made of straight lines, and the shape is "closed"
const Polygon = struct {
    points: []const Point = &.{}, //The list of points of the polygon. Each point must contain an x coordinate and a y coordinate. Required.
    fill: ?SvgColor = null,
    @"fill-opacity": ?f32 = null, // between 0 and 1
    stroke: ?SvgColor = null,
    @"stroke-width": ?f32 = null,
    @"stroke-opacity": ?f32 = null, // between 0 and 1
    pub fn parse(
        self: *@This(),
        maker: *NodeMaker,
        alloc: Allocator,
        att: []const []const u8,
        val: []const []const u8,
    ) !void {
        const Def = struct {
            pub const fill: ?SvgColor = undefined;
            pub const @"fill-opacity": ?f32 = undefined;
            pub const stroke: ?SvgColor = undefined;
            pub const @"stroke-width": ?f32 = undefined;
            pub const @"stroke-opacity": ?f32 = undefined;
        };
        for (att, val) |a, v| {
            try utils.auto_parse_def(@This(), self, Def, a, v);
            if (try utils.parsePointList(alloc, "points", a, v)) |res| {
                self.points = res.items;
            }
        }
        if (self.points.len < 3) return error.PolygonHasLessThan3Points;
        for (self.points, 0..) |p, i| {
            if (i == 0) {
                try maker.move(.{ .x = p.x, .y = p.y }, false);
            } else {
                try maker.line(.{ .x = p.x, .y = p.y }, false);
            }
        }
        try maker.close();
    }
};
const ParsePath = struct {};

const SvgPath = struct {
    d: ParsePath = ParsePath{}, //The list of points of the polygon. Each point must contain an x-  and a y-coordinate. Required.
    fill: ?SvgColor = null,
    @"fill-opacity": ?f32 = null, // between 0 and 1
    stroke: ?SvgColor = null,
    @"stroke-width": ?f32 = null,
    @"stroke-opacity": ?f32 = null, // between 0 and 1
    fn t2p(x: f32, y: f32) Point {
        return Point{ .x = x, .y = y };
    }
    pub fn parse(
        self: *@This(),
        maker: *NodeMaker,
        alloc: Allocator,
        att: []const []const u8,
        val: []const []const u8,
    ) !void {
        const Def = struct {
            pub const fill: ?SvgColor = undefined;
            pub const @"fill-opacity": ?f32 = undefined;
            pub const stroke: ?SvgColor = undefined;
            pub const @"stroke-width": ?f32 = undefined;
            pub const @"stroke-opacity": ?f32 = undefined;
        };
        for (att, val) |a, vx| {
            try utils.auto_parse_def(@This(), self, Def, a, vx);
        }
        for (att, val) |a, vx| {
            if (std.mem.eql(u8, a, "d")) {
                const nodes = try svg_ut.parse_path_data(alloc, vx);

                for (nodes) |cmd| {
                    switch (cmd.node_type) {
                        .move_to, .line_to => {
                            // [x, y]
                            if (cmd.values.len % 2 != 0) return error.InvalidValueCount;
                            for (cmd.values, 0..) |_, i| {
                                if (i % 2 == 0) {
                                    const x = cmd.values[i];
                                    const y = cmd.values[i + 1];
                                    if (i == 0 and cmd.node_type == .move_to) {
                                        try maker.move(t2p(x, y), cmd.rel);
                                    } else {
                                        try maker.line(t2p(x, y), cmd.rel);
                                    }
                                }
                            }
                        },
                        .horizontal_line_to, .vertical_line_to => {
                            // [x] or [y]
                            for (cmd.values) |v| {
                                if (cmd.node_type == .horizontal_line_to) {
                                    try maker.horiz(v, cmd.rel);
                                } else try maker.vert(v, cmd.rel);
                            }
                        },
                        .curve_to => {
                            // [x1 y1 x2 y2 x y] (multiple sets allowed)
                            if (cmd.values.len % 6 != 0) return error.InvalidValueCount;
                            var i: usize = 0;
                            while (i + 5 < cmd.values.len) : (i += 6) {
                                const x1 = cmd.values[i];
                                const y1 = cmd.values[i + 1];
                                const x2 = cmd.values[i + 2];
                                const y2 = cmd.values[i + 3];
                                const x = cmd.values[i + 4];
                                const y = cmd.values[i + 5];
                                try maker.curve_to(
                                    t2p(x1, y1),
                                    t2p(x2, y2),
                                    t2p(x, y),
                                    cmd.rel,
                                );
                            }
                        },
                        .smooth_curve_to => {
                            // [x2 y2 x y]
                            if (cmd.values.len % 4 != 0) return error.InvalidValueCount;
                            var i: usize = 0;
                            while (i + 3 < cmd.values.len) : (i += 4) {
                                const x2 = cmd.values[i];
                                const y2 = cmd.values[i + 1];
                                const x = cmd.values[i + 2];
                                const y = cmd.values[i + 3];
                                try maker.smooth_curve_to(
                                    t2p(x2, y2),
                                    t2p(x, y),
                                    cmd.rel,
                                );
                            }
                        },
                        .quadratic_bezier_curve_to => {
                            // [x1 y1 x y]
                            if (cmd.values.len % 4 != 0) return error.InvalidValueCount;
                            var i: usize = 0;
                            while (i + 3 < cmd.values.len) : (i += 4) {
                                const x1 = cmd.values[i];
                                const y1 = cmd.values[i + 1];
                                const x = cmd.values[i + 2];
                                const y = cmd.values[i + 3];
                                try maker.quadratic_bezier_curve_to(
                                    t2p(x1, y1),
                                    t2p(x, y),
                                    cmd.rel,
                                );
                            }
                        },
                        .smooth_quadratic_bezier_curve_to => {
                            // [x y]
                            if (cmd.values.len % 2 != 0) return error.InvalidValueCount;
                            for (cmd.values, 0..) |_, i| {
                                if (i % 2 == 0) {
                                    const x = cmd.values[i];
                                    const y = cmd.values[i + 1];
                                    try maker.smooth_quadratic_bezier_curve_to(
                                        t2p(x, y),
                                        cmd.rel,
                                    );
                                }
                            }
                        },
                        .elliptical_arc => {
                            // [rx ry x-axis-rotation large-arc-flag sweep-flag x y]
                            if (cmd.values.len % 7 != 0) return error.InvalidValueCount;
                            var i: usize = 0;
                            while (i + 6 < cmd.values.len) : (i += 7) {
                                const rx = cmd.values[i];
                                const ry = cmd.values[i + 1];
                                const rotation = cmd.values[i + 2];
                                const large_arc = cmd.values[i + 3] != 0;
                                const sweep = cmd.values[i + 4] != 0;
                                const x = cmd.values[i + 5];
                                const y = cmd.values[i + 6];
                                try maker.elliptical_arc(rx, ry, rotation, large_arc, sweep, t2p(x, y), cmd.rel);
                            }
                        },
                        .close_path => {
                            try maker.close();
                        },
                    }
                }
            }
        }
        try maker.flush();
    }
};
const G = struct {
    fill: ?SvgColor = null,
    @"fill-opacity": ?f32 = null, // between 0 and 1
    stroke: ?SvgColor = null,
    @"stroke-width": ?f32 = null,
    @"stroke-opacity": ?f32 = null, // between 0 and 1
    pub fn parse(
        self: *@This(),
        att: []const []const u8,
        val: []const []const u8,
    ) !void {
        const Def = struct {
            pub const fill: ?SvgColor = undefined;
            pub const @"fill-opacity": ?f32 = undefined;
            pub const stroke: ?SvgColor = undefined;
            pub const @"stroke-width": ?f32 = undefined;
            pub const @"stroke-opacity": ?f32 = undefined;
        };
        for (att, val) |a, v| {
            try utils.auto_parse_def(@This(), self, Def, a, v);
        }
    }
};

svg: Svg = Svg{},
xml_max_nesting: usize = 256,
default_stroke_width: f32 = 2,
default_color: SvgColor = .{ .col = Color{
    .r = 0.0,
    .g = 0.0,
    .b = 0.0,
    .a = 1.0,
} },
color_table: []const Color = &.{},
pub fn get_col(
    self: *const @This(),
    color: Color,
) !u32 {
    for (self.color_table, 0..) |c, i| {
        if (std.meta.eql(c, color)) return math.cast(u32, i) orelse return error.ColorOOB;
    }
    return error.ColorNotFound;
}

pub fn write_path(
    self: *const @This(),
    arena_alloc: Allocator,
    builder: anytype,
    pathlist: []Segment,
    stack: *const Stack(InheritableProperties),
) !void {
    return write_path_ctx(self, arena_alloc, builder, pathlist, stack, null, null);
}

/// Like `write_path`, but with the document's gradient table + `<svg>` so a
/// `fill="url(#id)"` can be resolved to a TinyVG linear/radial gradient. Pass
/// null for `gradients` on the color-table pre-pass (only flat colors matter
/// there).
pub fn write_path_ctx(
    self: *const @This(),
    arena_alloc: Allocator,
    builder: anytype,
    pathlist: []Segment,
    stack: *const Stack(InheritableProperties),
    gradients: ?*const GradientMap,
    svg: ?*const Svg,
) !void {
    const stroke_width = stack.top().?.@"stroke-width" orelse self.default_stroke_width;

    const fill = try InheritableProperties.resolve_paint_property(stack, "fill");
    const stroke = try InheritableProperties.resolve_paint_property(stack, "stroke");

    if (fill != .none) {
        const style = try self.paint_style(fill, gradients, svg);
        if (debug_write_path) std.log.warn("writeFillPath: {any}", .{pathlist});
        try builder.writeFillPath(style, pathlist);
    }
    if (stroke != .none) {
        for (pathlist) |*seg| {
            const node_dup = try arena_alloc.alloc(Node, seg.commands.len);
            for (seg.commands, node_dup) |n, *nd| {
                nd.* = n;
                switch (n) {
                    .line => nd.line.line_width = stroke_width,
                    .horiz => nd.horiz.line_width = stroke_width,
                    .vert => nd.vert.line_width = stroke_width,
                    .bezier => nd.bezier.line_width = stroke_width,
                    .arc_circle => nd.arc_circle.line_width = stroke_width,
                    .arc_ellipse => nd.arc_ellipse.line_width = stroke_width,
                    .close => nd.close.line_width = stroke_width,
                    .quadratic_bezier => nd.quadratic_bezier.line_width = stroke_width,
                }
            }
            seg.commands = node_dup;
        }
        const style = try self.paint_style(stroke, gradients, svg);
        if (debug_write_path) std.log.warn("writeDrawPath: {any}", .{pathlist});
        try builder.writeDrawPath(style, stroke_width, pathlist);
    }
}

/// Build a TinyVG `Style` from a resolved paint. A flat color indexes the color
/// table directly; a gradient reference resolves through `gradients` to a
/// `Style.linear`/`Style.radial` (endpoints mapped from the SVG user space into
/// the output space) and falls back to its first stop color when the gradient
/// is missing or unusable.
fn paint_style(
    self: *const @This(),
    paint: InheritableProperties.Paint,
    gradients: ?*const GradientMap,
    svg: ?*const Svg,
) !Style {
    switch (paint) {
        .none => return .{ .flat = 0 },
        .color => |c| return .{ .flat = try self.get_col(c) },
        .gradient => |id| {
            const map = gradients orelse return .{ .flat = 0 };
            const def = map.getPtr(id) orelse return .{ .flat = try self.get_col(.{ .r = 0, .g = 0, .b = 0, .a = 1 }) };
            return self.gradient_style(def, svg);
        },
    }
}

/// Resolve one `GradientDef` against the current `<svg>` viewBox into a TinyVG
/// linear or radial gradient style. TinyVG holds exactly two colors, so the
/// gradient's stops are reduced to the first and last (the icons' gradients are
/// two-to-three-stop brand ramps, which this approximates well).
fn gradient_style(self: *const @This(), def: *const GradientDef, svg: ?*const Svg) !Style {
    if (def.stops.items.len == 0) {
        return .{ .flat = try self.get_col(.{ .r = 0, .g = 0, .b = 0, .a = 1 }) };
    }
    const first = def.stops.items[0].color;
    const last = def.stops.items[def.stops.items.len - 1].color;
    const c0 = try self.add_color(first);
    const c1 = try self.add_color(last);

    // Map a gradient coordinate into the output space. `userSpaceOnUse` points
    // are in SVG user (viewBox) units and get the viewBox transform; the
    // default `objectBoundingBox` fractions are scaled by the viewBox size.
    const view = svg orelse return .{ .flat = c0 };
    const P = struct {
        fn map(vw: f32, vh: f32, x: f32, y: f32) Point {
            return .{ .x = x * vw, .y = y * vh };
        }
    };
    const vw = view.width orelse view.viewBox.w.?;
    const vh = view.height orelse view.viewBox.h.?;

    if (def.kind == .linear) {
        var p0 = Point{ .x = def.x1, .y = def.y1 };
        var p1 = Point{ .x = def.x2, .y = def.y2 };
        if (def.user_space) {
            p0 = view.transform(def.applyTransform(p0));
            p1 = view.transform(def.applyTransform(p1));
        } else {
            p0 = P.map(vw, vh, p0.x, p0.y);
            p1 = P.map(vw, vh, p1.x, p1.y);
        }
        // TinyVG's `linear` gradient is expressed as point_0 -> point_1 with
        // color_0 at the *far* end; keep the SVG order (0 at p0).
        return .{ .linear = .{ .point_0 = p1, .point_1 = p0, .color_0 = c1, .color_1 = c0 } };
    }

    // Radial: TinyVG's radial is a circle from point_0 (edge) to point_1
    // (center). Approximate the SVG focal with the ellipse center.
    var center = Point{ .x = def.cx, .y = def.cy };
    var edge = Point{ .x = def.cx + def.r, .y = def.cy };
    if (def.user_space) {
        center = view.transform(def.applyTransform(center));
        edge = view.transform(def.applyTransform(edge));
    } else {
        center = P.map(vw, vh, center.x, center.y);
        edge = P.map(vw, vh, edge.x, edge.y);
    }
    return .{ .radial = .{ .point_0 = edge, .point_1 = center, .color_0 = c1, .color_1 = c0 } };
}

/// Append a color to the output table, reusing an existing entry. Used by the
/// gradient path, which adds stop colors that the flat pre-pass did not see.
fn add_color(self: *const @This(), color: Color) !u32 {
    for (self.color_table, 0..) |c, i| {
        if (std.meta.eql(c, color)) return math.cast(u32, i) orelse return error.ColorOOB;
    }
    return error.ColorNotFound;
}

/// Parse every `<linearGradient>`/`<radialGradient>` paint server (with their
/// `<stop>`s, `gradientTransform`, `gradientUnits`, and `xlink:href`
/// inheritance) into `map`. Unknown elements are ignored; a malformed
/// gradient is skipped rather than failing the whole conversion.
fn parse_gradients(alloc: Allocator, svg_bytes: []const u8) !GradientMap {
    var map: GradientMap = .empty;
    errdefer {
        var it = map.iterator();
        while (it.next()) |kv| {
            alloc.free(kv.key_ptr.*);
            kv.value_ptr.deinit(alloc);
            if (kv.value_ptr.href) |h| alloc.free(h);
        }
        map.deinit(alloc);
    }
    var in: std.Io.Reader = .fixed(svg_bytes);
    var readerImpl: xml.Reader.Streaming = .init(alloc, &in, .{});
    defer readerImpl.deinit();
    var reader = &readerImpl.interface;

    const GradKind = enum { none, linear, radial, stop };
    var kind: GradKind = .none;
    // Ids of gradients currently open (nested `<defs>` never nests the same id,
    // but a stack keeps the parser robust).
    var current: ?[]const u8 = null;

    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => return error.MalformedXml,
            else => |other| return other,
        };
        switch (node) {
            .element_start => {
                const tag = reader.elementNameNs().local;
                const att_count = reader.attributeCount();
                if (std.mem.eql(u8, tag, "linearGradient") or std.mem.eql(u8, tag, "radialGradient")) {
                    kind = if (std.mem.eql(u8, tag, "linearGradient")) .linear else .radial;
                    var def = GradientDef{ .kind = if (kind == .linear) .linear else .radial };
                    var id: ?[]const u8 = null;
                    for (0..att_count) |i| {
                        const an = reader.attributeNameNs(i).local;
                        const av = try reader.attributeValue(i);
                        if (std.mem.eql(u8, an, "id")) {
                            id = try alloc.dupe(u8, av);
                        } else if (std.mem.eql(u8, an, "x1")) {
                            def.x1 = try parseLen(av, 0);
                        } else if (std.mem.eql(u8, an, "y1")) {
                            def.y1 = try parseLen(av, 0);
                        } else if (std.mem.eql(u8, an, "x2")) {
                            def.x2 = try parseLen(av, 1);
                        } else if (std.mem.eql(u8, an, "y2")) {
                            def.y2 = try parseLen(av, 0);
                        } else if (std.mem.eql(u8, an, "cx")) {
                            def.cx = try parseLen(av, 0.5);
                        } else if (std.mem.eql(u8, an, "cy")) {
                            def.cy = try parseLen(av, 0.5);
                        } else if (std.mem.eql(u8, an, "r")) {
                            def.r = try parseLen(av, 0.5);
                        } else if (std.mem.eql(u8, an, "fx")) {
                            def.fx = try parseLen(av, 0.5);
                        } else if (std.mem.eql(u8, an, "fy")) {
                            def.fy = try parseLen(av, 0.5);
                        } else if (std.mem.eql(u8, an, "gradientUnits")) {
                            def.user_space = std.mem.eql(u8, std.mem.trim(u8, av, " "), "userSpaceOnUse");
                        } else if (std.mem.eql(u8, an, "gradientTransform")) {
                            parseTransform(av, &def);
                        } else if (std.mem.eql(u8, an, "href") or std.mem.eql(u8, an, "xlink:href")) {
                            if (SvgColor.parseUrlRef(av)) |ref| def.href = try alloc.dupe(u8, ref);
                        }
                    }
                    if (id) |the_id| {
                        if (map.getPtr(the_id)) |existing| {
                            // Same id re-declared: replace in place, free the
                            // value's stop storage, and drop the redundant key.
                            existing.deinit(alloc);
                            existing.* = def;
                            alloc.free(the_id);
                        } else {
                            try map.put(alloc, the_id, def);
                        }
                        current = the_id;
                    } else {
                        // No id: keep the def unkeyed but still collect stops so
                        // a later href'd gradient is not the only source.
                        current = null;
                        if (def.href) |h| alloc.free(h);
                        def.deinit(alloc);
                    }
                } else if (std.mem.eql(u8, tag, "stop")) {
                    if (current) |id| {
                        var off: f32 = 0;
                        var col: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
                        for (0..att_count) |i| {
                            const an = reader.attributeNameNs(i).local;
                            const av = try reader.attributeValue(i);
                            if (std.mem.eql(u8, an, "offset")) off = try parseOffset(av);
                            if (std.mem.eql(u8, an, "stop-color")) col = try parseStopColor(av);
                            if (std.mem.eql(u8, an, "stop-opacity")) {
                                col.a = std.math.clamp(try std.fmt.parseFloat(f32, std.mem.trim(u8, av, " ")), 0, 1);
                            }
                        }
                        if (map.getPtr(id)) |def| {
                            try def.stops.append(alloc, .{ .offset = off, .color = col });
                        }
                    }
                }
            },
            .element_end => {
                const tag = reader.elementNameNs().local;
                if (std.mem.eql(u8, tag, "linearGradient") or std.mem.eql(u8, tag, "radialGradient")) {
                    kind = .none;
                    current = null;
                }
            },
            .eof => break,
            else => {},
        }
    }
    return map;
}

/// Parse a length/percentage for a gradient attribute (`0.5`, `50%`, `12`).
fn parseLen(val: []const u8, fallback: f32) !f32 {
    const t = std.mem.trim(u8, val, " ");
    if (t.len == 0) return fallback;
    if (std.mem.endsWith(u8, t, "%")) {
        const n = try std.fmt.parseFloat(f32, t[0 .. t.len - 1]);
        return n / 100.0;
    }
    return std.fmt.parseFloat(f32, t);
}

/// A `<stop offset>`: a number or a percentage.
fn parseOffset(val: []const u8) !f32 {
    const t = std.mem.trim(u8, val, " ");
    if (std.mem.endsWith(u8, t, "%")) {
        const n = try std.fmt.parseFloat(f32, t[0 .. t.len - 1]);
        return n / 100.0;
    }
    return std.fmt.parseFloat(f32, t);
}

fn parseStopColor(val: []const u8) !Color {
    var t = std.mem.trim(u8, val, " ");
    // SVG stop colors are `#rrggbb` (Color.fromString wants the bare hex).
    if (t.len > 0 and t[0] == '#') t = t[1..];
    // Expand the 3-digit shorthand (#abc -> #aabbcc).
    if (t.len == 3) {
        var buf: [6]u8 = undefined;
        buf[0] = t[0];
        buf[1] = t[0];
        buf[2] = t[1];
        buf[3] = t[1];
        buf[4] = t[2];
        buf[5] = t[2];
        return Color.fromString(&buf);
    }
    return Color.fromString(t);
}

/// Parse an SVG `transform` list, accumulating only the linear parts.
fn parseTransform(val: []const u8, def: *GradientDef) void {
    var i: usize = 0;
    while (i < val.len) {
        while (i < val.len and !std.ascii.isAlphabetic(val[i])) i += 1;
        const name_start = i;
        while (i < val.len and std.ascii.isAlphabetic(val[i])) i += 1;
        if (i == name_start) break;
        const name = val[name_start..i];
        const open = std.mem.indexOfScalarPos(u8, val, i, '(') orelse break;
        const close = std.mem.indexOfScalarPos(u8, val, open, ')') orelse break;
        const args = val[open + 1 .. close];
        i = close + 1;
        var nums: [6]f32 = .{ 0, 0, 0, 0, 0, 0 };
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, args, " ,");
        while (it.next()) |tok| {
            if (n >= nums.len) break;
            nums[n] = std.fmt.parseFloat(f32, tok) catch break;
            n += 1;
        }
        applyTransformFunc(name, nums[0..n], def);
    }
}

fn applyTransformFunc(name: []const u8, a: []const f32, def: *GradientDef) void {
    if (std.mem.eql(u8, name, "translate")) {
        const tx = a[0];
        const ty = if (a.len > 1) a[1] else 0;
        def.te += def.tx * tx + def.tz * ty;
        def.tf += def.ty * tx + def.tw * ty;
    } else if (std.mem.eql(u8, name, "scale")) {
        const sx = a[0];
        const sy = if (a.len > 1) a[1] else sx;
        def.tx *= sx;
        def.ty *= sx;
        def.tz *= sy;
        def.tw *= sy;
    } else if (std.mem.eql(u8, name, "matrix") and a.len >= 6) {
        const m = [6]f32{ a[0], a[1], a[2], a[3], a[4], a[5] };
        const ntx = def.tx * m[0] + def.tz * m[1];
        const nty = def.ty * m[0] + def.tw * m[1];
        const ntz = def.tx * m[2] + def.tz * m[3];
        const ntw = def.ty * m[2] + def.tw * m[3];
        const nte = def.tx * m[4] + def.tz * m[5] + def.te;
        const ntf = def.ty * m[4] + def.tw * m[5] + def.tf;
        def.tx = ntx;
        def.ty = nty;
        def.tz = ntz;
        def.tw = ntw;
        def.te = nte;
        def.tf = ntf;
    }
    // rotate/skew are not used by the icon packs; ignored.
}

pub fn parse_colors_and_svg(popts: *const @This(), gpa: Allocator, svg_bytes: []const u8) !struct { []const Color, Svg, GradientMap } {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var colormap: ColMap = .empty;

    var colortable_len: u32 = 0;
    try colormap.put(alloc, .fromColor(popts.default_color.col), colortable_len);
    colortable_len += 1;

    // Paint servers first: their `<stop>` colors must join the table so the
    // gradient styles can index them. The map is `gpa`-owned and returned to
    // the caller (the arena below dies at return).
    var gradients: GradientMap = try parse_gradients(gpa, svg_bytes);
    {
        var git = gradients.iterator();
        while (git.next()) |kv| {
            for (kv.value_ptr.stops.items) |st| {
                const key = ColorHash.fromColor(st.color);
                if (colormap.getKey(key) == null) {
                    try colormap.put(alloc, key, colortable_len);
                    colortable_len += 1;
                }
            }
        }
    }

    var in: std.Io.Reader = .fixed(svg_bytes);
    var readerImpl: xml.Reader.Streaming = .init(alloc, &in, .{});
    defer readerImpl.deinit();
    var reader = &readerImpl.interface;

    var svg = Svg{};

    while (true) {
        const xml_node = reader.read() catch |err| switch (err) {
            error.MalformedXml => {
                const loc = reader.errorLocation();
                std.log.err("{}:{}: {}", .{ loc.line, loc.column, reader.errorCode() });
                return error.MalformedXml;
            },
            else => |other| return other,
        };
        switch (xml_node) {
            .element_start => {
                const element_name = reader.elementNameNs();
                const element_tag = element_name.local;
                const att_count = reader.attributeCount();

                if (std.mem.eql(u8, "svg", element_tag)) {
                    const att_names = try alloc.alloc([]const u8, att_count);
                    const att_vals = try alloc.alloc([]const u8, att_count);
                    for (att_names, att_vals, 0..) |*n, *v, i| {
                        n.* = try alloc.dupe(u8, reader.attributeNameNs(i).local);
                        v.* = try alloc.dupe(u8, try reader.attributeValue(i));
                    }
                    try svg.parse(alloc, att_names, att_vals);
                }
                for (0..att_count) |i| {
                    const att_name = reader.attributeNameNs(i).local;
                    const att_val = try reader.attributeValue(i);
                    inline for (ColorProperties) |p| {
                        const c = try utils.parseColor(p, att_name, att_val);
                        if (c) |col| {
                            const maybe_key = ColorHash.get_hash_key(&col);
                            if (maybe_key) |key| {
                                if (colormap.getKey(key) == null) {
                                    try colormap.put(alloc, key, colortable_len);
                                    colortable_len += 1;
                                }
                            }
                        }
                    }
                }
            },
            else => {},
            .eof => break,
        }
    }
    try svg.check();
    const colors_hash = colormap.keys();
    const colors = try gpa.alloc(Color, colors_hash.len);

    if (debug) std.log.warn("colortable: RGBA", .{});
    for (colors, colors_hash, 0..) |*v, v2, i| {
        const c = v2.toColor();
        v.* = c;
        if (debug) std.log.warn("- {} | [{d:.1} {d:.1} {d:.1} {d:.1}]", .{ i, c.r, c.g, c.b, c.a });
    }
    return .{ colors, svg, gradients };
}

/// Free a `GradientMap` (keys, href/stop storage) allocated by
/// `parse_gradients`. Does not free the colors it references.
pub fn deinit_gradients(alloc: Allocator, map: *GradientMap) void {
    var it = map.iterator();
    while (it.next()) |kv| {
        alloc.free(kv.key_ptr.*);
        kv.value_ptr.deinit(alloc);
        if (kv.value_ptr.href) |h| alloc.free(h);
    }
    map.deinit(alloc);
}

pub fn tvg_from_svg(gpa: Allocator, svg_bytes: []const u8, opts: @This()) ![]const u8 {
    var popts = opts;
    const colors, const svg, var gradients = try parse_colors_and_svg(&popts, gpa, svg_bytes);
    defer gpa.free(colors);
    defer deinit_gradients(gpa, &gradients);
    popts.color_table = colors;
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    var builder = tvg.builder.create(&writer.writer);

    var in: std.Io.Reader = .fixed(svg_bytes);
    var readerImpl: xml.Reader.Streaming = .init(gpa, &in, .{});
    defer readerImpl.deinit();
    var reader = &readerImpl.interface;

    const sw: u32 = @intFromFloat(@round(svg.width.?));
    const sh: u32 = @intFromFloat(@round(svg.height.?));
    try builder.writeHeader(sw, sh, Scale.@"1/4096", .u8888, Range.enhanced);

    try builder.writeColorTable(colors);

    var stack = try Stack(InheritableProperties).init(gpa, popts.xml_max_nesting, InheritableProperties{});
    defer stack.deinit(gpa);

    // the fallback values
    try stack.push(InheritableProperties{
        .opacity = 1.0,
        .@"fill-opacity" = 1.0,
        .@"stroke-opacity" = 1.0,
        .@"stroke-width" = popts.default_stroke_width,
        .color = popts.default_color,
        .fill = popts.default_color,
        .stroke = popts.default_color,
    });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var found_svg_tag = false;
    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => {
                const loc = reader.errorLocation();
                std.log.err("{}:{}: {}", .{ loc.line, loc.column, reader.errorCode() });
                return error.MalformedXml;
            },
            else => |other| return other,
        };
        switch (node) {
            .element_start => {
                const garbage_alloc = arena.allocator();
                const element_name = reader.elementNameNs();
                const element_tag = element_name.local;
                if (!found_svg_tag) {
                    if (std.mem.eql(u8, "svg", element_tag)) {
                        found_svg_tag = true;
                        var props = InheritableProperties{};
                        props.override_from(svg);
                        try stack.push(props);
                    }
                } else {
                    const current_properties = stack.top() orelse InheritableProperties{};
                    try stack.push(current_properties);
                    const top_mut = stack.top_mut().?;
                    var maker = NodeMaker.init(garbage_alloc, svg);

                    const att_count = reader.attributeCount();
                    const att_names = try garbage_alloc.alloc([]const u8, att_count);
                    const att_vals = try garbage_alloc.alloc([]const u8, att_count);

                    for (att_names, att_vals, 0..) |*n, *v, i| {
                        n.* = try garbage_alloc.dupe(u8, reader.attributeNameNs(i).local);
                        v.* = try garbage_alloc.dupe(u8, try reader.attributeValue(i));
                    }
                    // Container
                    if (std.mem.eql(u8, "g", element_tag)) {
                        var element = G{};
                        try element.parse(att_names, att_vals);
                        top_mut.override_from(element);
                    } else
                    // Drawing Primitives
                    if (std.mem.eql(u8, "rect", element_tag)) {
                        var element = Rect{};
                        try element.parse(&maker, att_names, att_vals);
                        top_mut.override_from(element);
                        if (try maker.segments()) |segs| {
                            try write_path_ctx(&popts, garbage_alloc, &builder, segs, &stack, &gradients, &svg);
                        }
                    } else if (std.mem.eql(u8, "circle", element_tag)) {
                        var element = Circle{};
                        try element.parse(&maker, att_names, att_vals);
                        top_mut.override_from(element);
                        if (try maker.segments()) |segs| {
                            try write_path_ctx(&popts, garbage_alloc, &builder, segs, &stack, &gradients, &svg);
                        }
                    } else if (std.mem.eql(u8, "ellipse", element_tag)) {
                        var element = Ellipse{};
                        try element.parse(&maker, att_names, att_vals);
                        top_mut.override_from(element);
                        if (try maker.segments()) |segs| {
                            try write_path_ctx(&popts, garbage_alloc, &builder, segs, &stack, &gradients, &svg);
                        }
                    } else if (std.mem.eql(u8, "line", element_tag)) {
                        var element = Line{};
                        try element.parse(&maker, att_names, att_vals);
                        top_mut.override_from(element);
                        if (try maker.segments()) |segs| {
                            try write_path_ctx(&popts, garbage_alloc, &builder, segs, &stack, &gradients, &svg);
                        }
                    } else if (std.mem.eql(u8, "polyline", element_tag)) {
                        var element = PolyLine{};
                        try element.parse(&maker, garbage_alloc, att_names, att_vals);
                        top_mut.override_from(element);
                        if (try maker.segments()) |segs| {
                            try write_path_ctx(&popts, garbage_alloc, &builder, segs, &stack, &gradients, &svg);
                        }
                    } else if (std.mem.eql(u8, "polygon", element_tag)) {
                        var element = Polygon{};
                        try element.parse(&maker, garbage_alloc, att_names, att_vals);
                        top_mut.override_from(element);
                        if (try maker.segments()) |segs| {
                            try write_path_ctx(&popts, garbage_alloc, &builder, segs, &stack, &gradients, &svg);
                        }
                    } else if (std.mem.eql(u8, "path", element_tag)) {
                        var element = SvgPath{};
                        try element.parse(&maker, garbage_alloc, att_names, att_vals);
                        top_mut.override_from(element);

                        if (try maker.segments()) |segs| {
                            try write_path_ctx(&popts, garbage_alloc, &builder, segs, &stack, &gradients, &svg);
                            if (debug) log_seg(segs);
                        } else std.log.debug("no segments", .{});
                    } else if (std.mem.eql(u8, "defs", element_tag) or
                        std.mem.eql(u8, "linearGradient", element_tag) or
                        std.mem.eql(u8, "radialGradient", element_tag) or
                        std.mem.eql(u8, "stop", element_tag))
                    {
                        // Paint servers are already collected by
                        // `parse_gradients`; nothing to emit for them here.
                    } else {
                        std.log.warn("unrecognized element: {s}", .{element_tag});
                    }
                }
                _ = arena.reset(.retain_capacity);
            },
            .element_end => {
                _ = stack.pop();
            },
            else => {},
            .eof => break,
        }
    }
    try builder.writeEndOfFile();
    return writer.toOwnedSlice();
}
fn log_seg(segs: []const Segment) void {
    std.log.warn("PRINT SEG BEGIN", .{});
    for (segs) |sg| {
        ut.print_point("start", sg.start);
        for (sg.commands) |sn| {
            ut.print_node(sn);
        }
    }
    std.log.warn("PRINT SEG END", .{});
}

pub const make_node_debug = true and debug;
pub const debug_write_path = false;
pub const make_node_debug2 = false and debug;
const debug = false;
