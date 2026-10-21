const std = @import("std");

/// A method's wire types. ErrorCode must be an enum. Item = void is unary;
/// otherwise each stream chunk has type Item and the terminal result is Result.
pub fn Method(comptime ParamsType: type, comptime ResultType: type, comptime ErrorCodeType: type, comptime ItemType: type) type {
    validateType(ParamsType, 0);
    validateType(ResultType, 0);
    validateType(ItemType, 0);
    if (@typeInfo(ErrorCodeType) != .@"enum") @compileError("IPC error codes must be an enum");
    validateType(ErrorCodeType, 0);
    return struct {
        pub const Params = ParamsType;
        pub const Result = ResultType;
        pub const ErrorCode = ErrorCodeType;
        pub const Item = ItemType;
    };
}

/// An independent host-to-document notification payload; it has no request slot
/// or stream credit. Event schemas declare a named tuple of these types.
pub fn Event(comptime PayloadType: type) type {
    validateType(PayloadType, 0);
    return struct {
        pub const Payload = PayloadType;
    };
}

pub fn events(comptime Schema: type) []const std.builtin.Type.StructField {
    if (!@hasDecl(Schema, "events")) return &.{};
    // Validation walks every nested field; large schemas need room.
    @setEvalBranchQuota(100_000);
    const fields = @typeInfo(@TypeOf(Schema.events)).@"struct".fields;
    if (fields.len > 256) @compileError("IPC event schemas support at most 256 named events");
    inline for (fields) |field| validateType(@field(Schema.events, field.name).Payload, 0);
    return fields;
}

pub fn validateType(comptime T: type, comptime depth: usize) void {
    if (depth > 16) @compileError("IPC types must have finite nesting of at most 16 levels");
    if (T == void and depth != 0) @compileError("IPC void is only valid for a method's top-level type");
    switch (@typeInfo(T)) {
        .void, .bool => {},
        .@"enum" => |info| {
            if (!info.is_exhaustive) @compileError("IPC enums must be exhaustive");
            if (std.meta.hasFn(T, "jsonStringify") or std.meta.hasFn(T, "jsonParse") or std.meta.hasFn(T, "jsonParseFromValue")) @compileError("IPC types cannot customize their JSON encoding");
        },
        .int => |info| if (info.bits > 53) @compileError("IPC integers must fit JavaScript's exact integer range"),
        .float => |info| if (info.bits > 64) @compileError("IPC floats must be f32 or f64"),
        .optional => |info| validateType(info.child, depth + 1),
        .array => |info| validateType(info.child, depth + 1),
        .pointer => |info| {
            if (info.size != .slice) @compileError("IPC only supports slice pointers");
            if (info.child != u8) validateType(info.child, depth + 1);
        },
        .@"struct" => |info| {
            if (std.meta.hasFn(T, "jsonStringify") or std.meta.hasFn(T, "jsonParse") or std.meta.hasFn(T, "jsonParseFromValue")) @compileError("IPC types cannot customize their JSON encoding");
            if (info.is_tuple) @compileError("IPC structs must use named fields");
            inline for (info.fields) |field| {
                if (field.is_comptime) @compileError("IPC fields cannot be comptime");
                validateType(field.type, depth + 1);
            }
        },
        else => @compileError("Unsupported IPC wire type: " ++ @typeName(T)),
    }
}

/// Match JSON's actual shape before std.json's deliberately permissive coercions.
pub fn validateJson(comptime T: type, value: std.json.Value) !void {
    switch (@typeInfo(T)) {
        .void => if (value != .null) return error.InvalidParams,
        .bool => if (value != .bool) return error.InvalidParams,
        .int, .float => if (value != .integer and value != .float) return error.InvalidParams,
        .@"enum" => if (value != .string or std.meta.stringToEnum(T, value.string) == null) return error.InvalidParams,
        .optional => |info| if (value != .null) try validateJson(info.child, value),
        .array => |info| {
            if (info.child == u8) {
                if (value != .string or value.string.len != info.len) return error.InvalidParams;
            } else {
                if (value != .array or value.array.items.len != info.len) return error.InvalidParams;
                for (value.array.items) |item| try validateJson(info.child, item);
            }
        },
        .pointer => |info| {
            if (info.child == u8) {
                if (value != .string) return error.InvalidParams;
            } else {
                if (value != .array) return error.InvalidParams;
                for (value.array.items) |item| try validateJson(info.child, item);
            }
        },
        .@"struct" => |info| {
            if (value != .object) return error.InvalidParams;
            inline for (info.fields) |field| {
                if (value.object.get(field.name)) |item| {
                    try validateJson(field.type, item);
                } else if (field.default_value_ptr == null) return error.InvalidParams;
            }
        },
        else => unreachable,
    }
}

/// Output types are checked at compile time; their data must also be valid JSON.
pub fn validateValue(value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void, .bool, .int, .@"enum" => {},
        .float => if (!std.math.isFinite(value)) return error.NonFiniteNumber,
        .optional => if (value) |item| try validateValue(item),
        .array => |info| {
            if (info.child == u8) {
                if (!std.unicode.utf8ValidateSlice(&value)) return error.InvalidUtf8;
            } else for (value) |item| try validateValue(item);
        },
        .pointer => |info| {
            if (info.child == u8) {
                if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
            } else for (value) |item| try validateValue(item);
        },
        .@"struct" => |info| inline for (info.fields) |field| try validateValue(@field(value, field.name)),
        else => unreachable,
    }
}

pub fn methods(comptime Service: type) []const std.builtin.Type.StructField {
    @setEvalBranchQuota(100_000);
    if (!@hasDecl(Service, "methods")) {
        if (events(Service).len != 0) return &.{};
        @compileError("An IPC schema must declare methods or events");
    }
    const fields = @typeInfo(@TypeOf(Service.methods)).@"struct".fields;
    if (fields.len == 0 and events(Service).len == 0) @compileError("An IPC schema must declare methods or events");
    inline for (fields) |field| {
        for (.{ "receive", "close", "pendingCount", "__proto__", "constructor", "prototype" }) |reserved| {
            if (std.mem.eql(u8, field.name, reserved)) @compileError("Reserved IPC method name: " ++ field.name);
        }
        if (events(Service).len != 0) for (.{ "on", "listenerCount", "subscriptionCount" }) |reserved| {
            if (std.mem.eql(u8, field.name, reserved)) @compileError("Reserved IPC event API name: " ++ field.name);
        };
        const M = @field(Service.methods, field.name);
        validateType(M.Params, 0);
        validateType(M.Result, 0);
        validateType(M.Item, 0);
        if (@typeInfo(M.ErrorCode) != .@"enum") @compileError("IPC error codes must be an enum");
        validateType(M.ErrorCode, 0);
    }
    return fields;
}

pub fn MethodTag(comptime Service: type) type {
    _ = methods(Service);
    return std.meta.FieldEnum(@TypeOf(Service.methods));
}

pub fn ParamsUnion(comptime Service: type) type {
    const fields = methods(Service);
    var union_fields: [fields.len]std.builtin.Type.UnionField = undefined;
    for (fields, 0..) |field, index| {
        const T = @field(Service.methods, field.name).Params;
        union_fields[index] = .{ .name = field.name, .type = T, .alignment = @alignOf(T) };
    }
    return @Type(.{ .@"union" = .{ .layout = .auto, .tag_type = MethodTag(Service), .fields = &union_fields, .decls = &.{} } });
}
