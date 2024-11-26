const std = @import("std");
const print = std.debug.print;

const PdfObjectType = enum { ref, name, number, text, dictionary, array, stream, special, page };

const PdfObject = union(PdfObjectType) {
    ref: Ref,
    name: []const u8,
    number: u64,
    text: []const u8,
    dictionary: Dictionary,
    array: []const PdfObject,
    stream: Stream,
    special: void,
    page: Page,

    const Ref = struct { number: u64, generation: u64 };

    const Dictionary = struct {
        pairs: []const Pair,

        const Pair = struct { key: PdfObject, value: PdfObject };

        pub fn pair(key: PdfObject, value: PdfObject) Pair {
            return .{ .key = key, .value = value };
        }
    };

    const Stream = struct {
        length: u64,
        str: []const u8,
        font: []const u8,
    };

    const Page = struct {
        parent: u64,
        mediabox: ?[4]u64,
        resources: u64,
        contents: u64,
    };

    pub fn encodeln(ss: *std.io.StreamSource, obj: PdfObject) !void {
        try encode(ss, obj);
        try ss.writer().print("\n", .{});
    }

    pub fn encode(ss: *std.io.StreamSource, obj: PdfObject) !void {
        const writer = ss.writer();

        switch (obj) {
            .ref => {
                try writer.print("{d} {d} R", .{ obj.ref.number, obj.ref.generation });
            },
            .name => {
                try writer.print("{s}", .{obj.name});
            },
            .number => try writer.print("{d}", .{obj.number}),
            .text => {
                try writer.print("({s}) Tj", .{obj.text});
            },
            .dictionary => {
                try writer.print("<<\n", .{});
                for (obj.dictionary.pairs) |pair| {
                    try PdfObject.encode(ss, pair.key);
                    try writer.print(" ", .{});
                    try PdfObject.encode(ss, pair.value);
                    try writer.print("\n", .{});
                }
                try writer.print(">>", .{});
            },
            .array => {
                try writer.print("[", .{});
                for (obj.array, 0..) |elm, quantity| {
                    if (quantity > 0)
                        try writer.print(" ", .{});
                    try encode(ss, elm);
                }
                try writer.print("]", .{});
            },
            .stream => {
                try writer.print("<<\n/Length {d}\n>>\n", .{obj.stream.length});
                try writer.print("stream\n", .{});
                try writer.print("1. 0. 0. 50. 720. cm\n", .{});
                try writer.print("BT\n", .{});
                try writer.print("/undefined undefined Tf\n", .{});
                try writer.print("({s})\n", .{obj.stream.str});
                try writer.print("ET\n", .{});
                try writer.print("endstream", .{});
            },
            .page => {
                try writer.print("<<\n", .{});
                try writer.print("/Parent {d} {d} R\n", .{ obj.page.parent, 0 });
                if (obj.page.mediabox) |mediabox| {
                    try writer.print("/MediaBox [{d} {d} {d} {d}]\n", .{ mediabox[0], mediabox[1], mediabox[2], mediabox[3] });
                }
                try writer.print("/Resources {d} {d} R\n", .{ obj.page.resources, 0 });
                try writer.print("/Contents {d} {d} R\n", .{ obj.page.contents, 0 });
                try writer.print("/Type /Page\n", .{});
                try writer.print(">>", .{});
            },
            .special => {},
            // else => {},
        }
    }

    pub fn ref(obj_number: u64, obj_generation: u64) PdfObject {
        return .{ .ref = .{ .number = obj_number, .generation = obj_generation } };
    }

    pub fn name(inner: []const u8) PdfObject {
        return .{ .name = inner };
    }

    pub fn number(inner: u64) PdfObject {
        return .{ .number = inner };
    }

    pub fn text(inner: []const u8) PdfObject {
        return .{ .text = inner };
    }

    pub fn dictionary(pairs: []const Dictionary.Pair) PdfObject {
        return .{ .dictionary = .{ .pairs = pairs } };
    }

    pub fn array(inner: []const PdfObject) PdfObject {
        return .{ .array = inner };
    }

    pub fn stream(str: []const u8, font: []const u8) PdfObject {
        return .{ .stream = .{ .str = str, .font = font, .length = str.len } };
    }

    pub fn special() PdfObject {
        return .{ .special = {} };
    }

    // TODO: translate or hardcode PDF Object?
    pub fn page(parent: u64, mediabox: [4]u64, resources: u64, contents: u64) PdfObject {
        return .{ .page = .{ .parent = parent, .mediabox = mediabox, .resources = resources, .contents = contents } };
    }
};

const PdfEncoder = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(PdfObject),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .objects = std.ArrayList(PdfObject).init(allocator),
        };
    }

    pub fn addText(self: *Self, text: []const u8) !void {
        try self.add(PdfObject.text(text));
    }

    pub fn addStream(self: *Self, str: []const u8, font: []const u8) !void {
        try self.add(PdfObject.stream(str, font));
    }

    pub fn add(self: *Self, obj: PdfObject) !void {
        try self.objects.append(obj);
    }

    pub fn encode(self: *Self, ss: *std.io.StreamSource) !void {
        const file = ss.file;
        const writer = ss.writer();

        // header
        try writer.print("%PDF-1.7\n", .{});
        try writer.print("%\xe2\xe3\xcf\xd3\n", .{});

        // body
        var root = std.ArrayList(PdfObject).init(self.allocator);
        defer root.deinit();
        try root.append(PdfObject.special());

        const catalog = PdfObject.dictionary(&[_]PdfObject.Dictionary.Pair{
            PdfObject.Dictionary.pair(PdfObject.name("/Type"), PdfObject.name("/Catalog")),
            PdfObject.Dictionary.pair(PdfObject.name("/Pages"), PdfObject.ref(2, 0)),
        });

        const tree = PdfObject.dictionary(&[_]PdfObject.Dictionary.Pair{
            PdfObject.Dictionary.pair(PdfObject.name("/Kids"), PdfObject.array(&[_]PdfObject{PdfObject.ref(3, 0)})),
            PdfObject.Dictionary.pair(PdfObject.name("/Count"), PdfObject.number(1)),
        });

        const page = PdfObject.page(2, [4]u64{ 0, 0, 595, 842 }, 4, 5);

        try root.append(catalog);
        try root.append(tree);
        try root.append(page);

        // TODO:
        for (self.objects.items) |obj| {
            try root.append(obj);
        }

        var cross_reference_table = std.ArrayList(u64).init(self.allocator);
        defer cross_reference_table.deinit();

        // prevent special object whose number is 0
        _ = root.orderedRemove(0);

        for (root.items, 1..) |obj, number| {
            // TODO: replace more efficiency method
            const stat = try file.stat();
            const byte_offset = stat.size;
            try cross_reference_table.append(byte_offset);

            try writer.print("{d} {d} obj\n", .{ number, 0 });
            try PdfObject.encodeln(ss, obj);
        }

        // cross reference table
        try writer.print("xref\n", .{});
        try writer.print("{d} {d}\n", .{ 0, cross_reference_table.items.len });
        for (cross_reference_table.items) |byte_offset| {
            // don't remove space from end of entry
            try writer.print("{d:0>10} undefined undefined \n", .{byte_offset});
        }

        // trailer
        try writer.print("trailer\n", .{});
        try writer.print("<<\n", .{});
        try writer.print("/Root 1 0 R\n", .{});
        try writer.print("/Size {d}\n", .{cross_reference_table.items.len});
        try writer.print(">>\n", .{});
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var pdf_encoder = PdfEncoder.init(allocator);
    try pdf_encoder.addStream("hello, world", "Times New Roman");
    try pdf_encoder.addStream("im fine", "Times New Roman");
    try pdf_encoder.addStream("thank you!", "Times New Roman");
    var ss = std.io.StreamSource{ .file = try std.fs.cwd().createFile("main.pdf", .{}) };
    try pdf_encoder.encode(&ss);
}
