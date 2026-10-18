//! Pure packet code. No Zig owner or allocator crosses this ABI. The C caller
//! owns a fully validated immutable packet and pins its arrays for each query.
const hit = @import("ziggurat_prepared_hit");

fn code(err: anyerror) c_int {
    return switch (err) {
        error.CapacityExceeded, error.WorkLimit => 1,
        else => 4,
    };
}

export fn zde_prepared_hit_validate(packet: *const hit.Packet, stops: u32, lines: u32, work: u64, position: u64) callconv(.c) c_int {
    hit.validate(packet, .{ .stops = stops, .lines = lines, .work = work, .position = position }) catch |err| return code(err);
    return 0;
}

export fn zde_prepared_hit_query(packet: *const hit.Packet, x: f32, y: f32, out: *hit.Result) callconv(.c) c_int {
    const result = hit.query(packet, .{ .x = x, .y = y }) catch |err| return code(err);
    out.* = result;
    return 0;
}
