const std = @import("std");
const print = std.debug.print;

const PdfObjectType = enum { ref, name, text, dictionary, stream };

const PdfObject = union(PdfObjectType) {
    ref: Ref,
    name: []const u8,
    text: []const u8,
    dictionary: Dictionary,

    const Ref = struct { number: u64, generation: u64 };

    const Dictionary = struct {
        pairs: []const Pair,

        const Pair = struct { key: PdfObject, value: PdfObject };

        pub fn pair(key: PdfObject, value: PdfObject) Pair {
            return .{ .key = key, .value = value };
        }
    };

    const Stream = struct {
        length: Dictionary,
    };

    pub fn ref(number: u64, generation: u64) PdfObject {
        return .{ .ref = .{ .number = number, .generation = generation } };
    }

    pub fn name(inner: []const u8) PdfObject {
        return .{ .name = inner };
    }

    pub fn text(inner: []const u8) PdfObject {
        return .{ .text = inner };
    }

    pub fn dictionary(pairs: []const Dictionary.Pair) PdfObject {
        return .{ .dictionary = .{ .pairs = pairs } };
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

    pub fn add(self: *Self, obj: PdfObject) !void {
        try self.objects.append(obj);
    }

    pub fn encode(self: *Self, ss: *std.io.StreamSource) !void {
        const file = ss.file;
        const writer = ss.writer();

        // header
        try writer.print("%PDF-1.7\n", .{});

        // body
        var root = std.ArrayList(PdfObject).init(self.allocator);
        defer root.deinit();
        try root.append(PdfObject.dictionary(&[_]PdfObject.Dictionary.Pair{
            PdfObject.Dictionary.pair(PdfObject.name("/Pages"), PdfObject.ref(2, 0)),
            PdfObject.Dictionary.pair(PdfObject.name("/Type"), PdfObject.name("/Catalog")),
        }));

        // TODO:
        for (self.objects.items) |obj| {
            try root.append(obj);
        }

        var cross_reference_table = std.ArrayList(u64).init(self.allocator);
        defer cross_reference_table.deinit();

        for (root.items, 0..) |obj, number| {
            // TODO: replace more efficiency method
            const stat = try file.stat();
            const byte_offset = stat.size;
            try cross_reference_table.append(byte_offset);

            try PdfObject.encode(obj, writer);

            switch (obj) {
                .text => {
                    try writer.print("{d} {d} obj\n", .{ number, 0 });
                    try writer.print("<< >>\n", .{});
                    try writer.print("stream\n", .{});
                    try writer.print("BT\n", .{});
                    try writer.print("({s}) Tj\n", .{obj.text});
                    try writer.print("ET\n", .{});
                    try writer.print("endstream\n", .{});
                    try writer.print("endobj\n", .{});
                },
                .dictionary => {
                    try writer.print("<<\n", .{});
                    // try writer.print("")
                    try writer.print(">>\n", .{});
                },
                else => {},
            }
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
        try writer.print("/Root undefined undefined R\n", .{});
        try writer.print("/Size undefined\n", .{});
        try writer.print(">>\n", .{});
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var pdf_encoder = PdfEncoder.init(allocator);
    try pdf_encoder.addText("hello, world");
    try pdf_encoder.addText("im fine");
    try pdf_encoder.addText("thank you!");
    var ss = std.io.StreamSource{ .file = try std.fs.cwd().createFile("main.pdf", .{}) };
    try pdf_encoder.encode(&ss);
}
