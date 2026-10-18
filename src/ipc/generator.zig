const std = @import("std");
const schema = @import("schema.zig");

/// Returns an owned standalone TypeScript module, including its runtime.
/// Both host and generated code use protocol version 1 and caller-owned transport.
pub fn generate(comptime Service: type, allocator: std.mem.Allocator) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    write(Service, &output.writer) catch |err| {
        if (err == error.WriteFailed) return error.OutOfMemory;
        return err;
    };
    return output.toOwnedSlice();
}

fn write(comptime Service: type, writer: *std.Io.Writer) !void {
    try writer.writeAll("// Generated from Zig service types. Protocol version 1.\nexport type Methods = {\n");
    inline for (schema.methods(Service)) |field| {
        const M = @field(Service.methods, field.name);
        try quoted(writer, field.name);
        try writer.writeAll(": { params: ");
        try tsType(M.Params, writer);
        try writer.writeAll("; result: ");
        try tsType(M.Result, writer);
        try writer.writeAll("; error: ");
        try tsType(M.ErrorCode, writer);
        try writer.writeAll("; item: ");
        if (M.Item == void) try writer.writeAll("never") else try tsType(M.Item, writer);
        try writer.writeAll(" };\n");
    }
    try writer.writeAll("};\nconst methodSpecs: Record<keyof Methods, Spec> = {\n");
    inline for (schema.methods(Service)) |field| {
        const M = @field(Service.methods, field.name);
        try writer.writeAll("[");
        try quoted(writer, field.name);
        try writer.print("]: {{ stream: {s}, params: ", .{if (M.Item == void) "false" else "true"});
        try shape(M.Params, writer);
        try writer.writeAll(", result: ");
        try shape(M.Result, writer);
        try writer.writeAll(", item: ");
        try shape(M.Item, writer);
        try writer.writeAll(", errors: [");
        inline for (@typeInfo(M.ErrorCode).@"enum".fields, 0..) |error_field, index| {
            if (index != 0) try writer.writeAll(",");
            try quoted(writer, error_field.name);
        }
        try writer.writeAll("] },\n");
    }
    try writer.writeAll("};\nexport type Events = {\n");
    inline for (schema.events(Service)) |field| {
        try quoted(writer, field.name);
        try writer.writeAll(": ");
        try tsType(@field(Service.events, field.name).Payload, writer);
        try writer.writeAll(";\n");
    }
    try writer.writeAll("};\nconst eventSpecs: Record<keyof Events, Shape> = {\n");
    inline for (schema.events(Service)) |field| {
        try writer.writeAll("[");
        try quoted(writer, field.name);
        try writer.writeAll("]: ");
        try shape(@field(Service.events, field.name).Payload, writer);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("};\n");
    try writer.writeAll(@embedFile("client.ts.in"));
}

fn quoted(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

fn tsType(comptime T: type, writer: *std.Io.Writer) anyerror!void {
    switch (@typeInfo(T)) {
        .void => try writer.writeAll("undefined"),
        .bool => try writer.writeAll("boolean"),
        .int, .float => try writer.writeAll("number"),
        .optional => |info| {
            try writer.writeAll("(");
            try tsType(info.child, writer);
            try writer.writeAll(" | null)");
        },
        .@"enum" => |info| {
            if (info.fields.len == 0) try writer.writeAll("never");
            inline for (info.fields, 0..) |field, index| {
                if (index != 0) try writer.writeAll(" | ");
                try quoted(writer, field.name);
            }
        },
        .array => |info| {
            if (info.child == u8) return writer.writeAll("string");
            try writer.writeAll("readonly [");
            for (0..info.len) |index| {
                if (index != 0) try writer.writeAll(", ");
                try tsType(info.child, writer);
            }
            try writer.writeAll("]");
        },
        .pointer => |info| {
            if (info.child == u8) return writer.writeAll("string");
            try writer.writeAll("ReadonlyArray<");
            try tsType(info.child, writer);
            try writer.writeAll(">");
        },
        .@"struct" => |info| {
            try writer.writeAll("{ ");
            inline for (info.fields) |field| {
                try quoted(writer, field.name);
                try writer.writeAll(if (field.default_value_ptr != null) "?: " else ": ");
                try tsType(field.type, writer);
                try writer.writeAll("; ");
            }
            try writer.writeAll("}");
        },
        else => unreachable,
    }
}

fn shape(comptime T: type, writer: *std.Io.Writer) anyerror!void {
    switch (@typeInfo(T)) {
        .void => try writer.writeAll("{kind:'void'}"),
        .bool => try writer.writeAll("{kind:'bool'}"),
        .float => try writer.print("{{kind:'number',min:{e},max:{e}}}", .{ -std.math.floatMax(T), std.math.floatMax(T) }),
        .int => try writer.print("{{kind:'number',integer:true,min:{d},max:{d}}}", .{ std.math.minInt(T), std.math.maxInt(T) }),
        .optional => |info| {
            try writer.writeAll("{kind:'optional',child:");
            try shape(info.child, writer);
            try writer.writeAll("}");
        },
        .@"enum" => |info| {
            try writer.writeAll("{kind:'enum',values:[");
            inline for (info.fields, 0..) |field, index| {
                if (index != 0) try writer.writeAll(",");
                try quoted(writer, field.name);
            }
            try writer.writeAll("]}");
        },
        .array => |info| {
            if (info.child == u8) return writer.print("{{kind:'string',length:{d}}}", .{info.len});
            try writer.print("{{kind:'array',length:{d},child:", .{info.len});
            try shape(info.child, writer);
            try writer.writeAll("}");
        },
        .pointer => |info| {
            if (info.child == u8) return writer.writeAll("{kind:'string'}");
            try writer.writeAll("{kind:'array',child:");
            try shape(info.child, writer);
            try writer.writeAll("}");
        },
        .@"struct" => |info| {
            try writer.writeAll("{kind:'object',fields:[");
            inline for (info.fields, 0..) |field, index| {
                if (index != 0) try writer.writeAll(",");
                try writer.writeAll("{name:");
                try quoted(writer, field.name);
                try writer.print(",optional:{s},shape:", .{if (field.default_value_ptr != null) "true" else "false"});
                try shape(field.type, writer);
                try writer.writeAll("}");
            }
            try writer.writeAll("]}");
        },
        else => unreachable,
    }
}
