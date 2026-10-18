pub const Account = opaque {};
pub const State = opaque {};
pub const Text = opaque {};
pub const Geometry = opaque {};
pub const AuxPlan = opaque {};
pub const AuxKey = @import("auxiliary.zig").Key;
/// expanded packs bit0=expanded, bit1=keyboard-focusable; other bits rejected.
pub const AuxNode = extern struct { key: AuxKey, frame_id: u64, parent: u32, name_start: u32, name_length: u32, expanded: u32 };
pub const Publication = extern struct { generation: u64 = 0, publication: u64 = 0, source: u64 = 0, candidate: u64 = 0, space_epoch: u64 = 0, space_generation: u64 = 0 };
pub const AuxAccepted = extern struct { key: AuxKey, presentation_epoch: u64, flags: u32, reserved: u32, frame_id: u64, publication: Publication };
pub const AuxGeometry = extern struct { x: f64, y: f64, width: f64, height: f64, flags: u32, reserved: u32 = 0 };
pub const AuxAction = extern struct { context: ?*anyopaque, key: AuxKey, presentation_epoch: u64, kind: u32, reserved: u32, publication: Publication };
pub const Error = extern struct { domain: u32 = 0, code: i32 = 0 };
pub const Rect = extern struct { x: f64, y: f64, width: f64, height: f64 };
pub const Point = extern struct { x: f64, y: f64 };
pub const Mapping = extern struct { forward: [6]f64, inverse: [6]f64, polygon: [132]Point = undefined, count: u32, reserved: u32 = 0 };
pub const Cell = extern struct { start: u32, end: u32, rectangle: Rect };
pub const Caret = extern struct { position: u32, affinity: u32, rectangle: Rect };
pub const Line = extern struct { first: u32, count: u32, rectangle: Rect };
pub const Selection = extern struct { anchor: u32, caret: u32 };
pub const Source = extern struct { name: [*]const u16, name_length: u32, read_only: u32, selectable: u32, focusable: u32, scrollable: u32 };
pub const TextInput = extern struct { text_version: u64, text: [*]const u16, scalars: [*]const u32, paragraphs: [*]const u32, text_length: u32, scalar_count: u32, paragraph_count: u32 };
pub extern fn zda_native_enable_words(*State) c_int;
pub const Metadata = extern struct { text_version: u64, revision: u64, selections: [*]const Selection, selection_count: u32, primary: u32, focused: u32, enabled: u32, composing: u32 };
pub const GeometryInput = extern struct { text_version: u64, projection_version: u64, bounds: Rect, cells: [*]const Cell, cell_count: u32, scale: f64, carets: ?[*]const Caret = null, caret_count: u32 = 0, lines: ?[*]const Line = null, line_count: u32 = 0 };
pub const Action = extern struct { context: ?*anyopaque, text_version: u64, revision: u64, presentation_epoch: u64, source: u32, kind: u32, start: u32, end: u32, align_top: u32 };
comptime {
    if (@sizeOf(usize) == 8 and (@sizeOf(Action) != 56 or @offsetOf(Action, "presentation_epoch") != 24)) @compileError("presentation action ABI");
    if (@sizeOf(AuxKey) != 32 or @sizeOf(AuxNode) != 56 or @sizeOf(AuxGeometry) != 40 or (@sizeOf(usize) == 8 and @sizeOf(AuxAction) != 104)) @compileError("auxiliary semantic ABI");
    if (@sizeOf(AuxAccepted) != 104 or @sizeOf(Publication) != 48) @compileError("accepted auxiliary ABI");
}
pub const Stats = extern struct { bytes: u64, peak_bytes: u64, byte_limit: u64, host_bytes: u64, states: u32, providers: u32, ranges: u32, blobs: u32, range_limit: u32 };
pub extern fn zda_native_create(?*anyopaque, [*]const Source, u32, u64, u32, u32, *const fn (*anyopaque, *anyopaque) callconv(.c) c_int, *anyopaque, *Error, *?*State) c_int;
pub extern fn zda_native_text(*State, *const TextInput, *?*Text) c_int;
pub extern fn zda_text_release(?*Text) void;
pub extern fn zda_native_geometry(*State, *const GeometryInput, *?*Geometry) c_int;
pub extern fn zda_geometry_release(?*Geometry) void;
pub extern fn zda_native_publish(*State, [*]const ?*Text, [*]const Metadata, u32) c_int;
pub extern fn zda_native_publish_geometry(*State, [*]const ?*Geometry, u32) c_int;
pub extern fn zda_native_enable_mapping(*State) c_int;
pub extern fn zda_native_publish_mapped(*State, [*]const ?*Geometry, [*]const Mapping, u32) c_int;
pub extern fn zda_native_enable_presentation(*State) c_int;
pub extern fn zda_native_publish_presented(*State, [*]const ?*Geometry, ?[*]const Mapping, u32, u64) c_int;
pub extern fn zda_native_enable_auxiliary(*State, u32) c_int;
pub extern fn zda_native_enable_auxiliary_mapping(*State) c_int;
pub extern fn zda_native_auxiliary(*State, [*]const AuxNode, u32, [*]const u16, u32, *?*AuxPlan) c_int;
pub extern fn zda_auxiliary_release(?*AuxPlan) void;
pub extern fn zda_native_publish_auxiliary(*State, [*]const ?*Geometry, u32, u64, ?*AuxPlan, ?[*]const AuxGeometry, u32, f64) c_int;
pub extern fn zda_native_publish_auxiliary_mapped(*State, [*]const ?*Geometry, ?[*]const Mapping, u32, u64, ?*AuxPlan, ?[*]const AuxGeometry, u32, f64, ?*const Mapping, ?*const Publication) c_int;
pub extern fn zda_native_auxiliary_provider(*State, *const AuxKey) ?*anyopaque;
pub extern fn zda_native_auxiliary_accepted(*State, u64, *AuxAccepted) c_int;
pub extern fn zda_native_auxiliary_accepted_key(*State, *const AuxKey, *AuxAccepted) c_int;
pub extern fn zda_native_take_auxiliary_action(*anyopaque, *AuxAction) c_int;
pub extern fn zda_native_invalidate(*State, u32) void;
pub extern fn zda_native_position(*State, f64, f64, f64) c_int;
pub extern fn zda_native_begin_close(*State) void;
pub extern fn zda_native_disconnect(*State) i32;
pub extern fn zda_native_object(*State, usize, isize) isize;
pub extern fn zda_native_provider(*State, u32) ?*anyopaque;
pub extern fn zda_native_stats(*State, *Stats) void;
pub extern fn zda_native_account(*State) *Account;
pub extern fn zda_account_release(*Account) void;
pub extern fn zda_account_reserve_host(*Account, usize) c_int;
pub extern fn zda_account_release_host(*Account, usize) void;
pub extern fn zda_native_take_action(*anyopaque, *Action) c_int;
pub extern fn zda_native_finish_action(*anyopaque) void;
pub extern fn zda_ledger_counts(*u32, *u32, *u64) void;

// Linux creates a C-only provider before borrowing the current Window native
// record. Only prepare/mount cross the private, opt-in GTK host boundary.
pub extern fn zda_linux_create([*]const Source, u32, u64, u32, u32, *Error, *?*State) c_int;
pub extern fn zda_linux_prepare(*State, *anyopaque) c_int;
pub extern fn zda_linux_mount(*State) c_int;
pub extern fn zda_linux_live(*State) c_int;
pub extern fn zda_linux_position(*State, *f64) c_int;
pub const HitInput = extern struct {
    revision: u64,
    text_version: u64,
    projection_version: u64,
    geometry_generation: u64,
    scale: f64,
    domain: u32,
    reserved: u32 = 0,
    packet: @import("ziggurat_document_editor").HitPacket,
};
pub const LinuxHitInput = HitInput;
pub extern fn zda_native_geometry_hit(*State, u32, *const GeometryInput, *const HitInput, *?*Geometry) c_int;
pub extern fn zda_native_withdraw_geometry(*State, u32) void;
pub extern fn zda_store_retain(*State) void;
pub extern fn zda_store_release(*State) void;
pub extern fn zda_linux_geometry_hit(*State, *const GeometryInput, *const LinuxHitInput, *?*Geometry) c_int;
pub extern fn zda_linux_retain(*State) void;
pub extern fn zda_linux_release(*State) void;
pub extern fn zlg_accessibility_host_available(*anyopaque) c_int;

pub fn linuxCheck(code: c_int) !void {
    return switch (code) {
        6 => error.Busy,
        7 => error.UnsupportedCapability,
        else => check(code),
    };
}

pub fn check(code: c_int) !void {
    return switch (code) {
        0 => {},
        1 => error.CapacityExceeded,
        2 => error.Closed,
        3 => error.OutOfMemory,
        4 => error.InvalidNativeInput,
        else => error.NativeUnavailable,
    };
}
