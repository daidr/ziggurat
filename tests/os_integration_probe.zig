//! Linux GIO observers for the OS integration smoke; see os_integration_probe.c.
pub extern fn probe_setenv(name: [*:0]const u8, value: [*:0]const u8) c_int;
pub extern fn probe_default_for_scheme(scheme: [*:0]const u8, out: [*]u8, capacity: usize) c_int;
pub extern fn probe_default_for_type(mime: [*:0]const u8, out: [*]u8, capacity: usize) c_int;
pub extern fn probe_guess(filename: [*:0]const u8, out: [*]u8, capacity: usize) c_int;
pub extern fn probe_launch_uri(uri: [*:0]const u8) c_int;
pub extern fn probe_start(want_logind: c_int) c_int;
pub extern fn probe_stop() void;
pub extern fn probe_logind_wait(calls: c_int, timeout_ms: c_int, what: [*]u8, who: [*]u8, why: [*]u8, mode: [*]u8) c_int;
pub extern fn probe_logind_released(timeout_ms: c_int) c_int;
pub extern fn probe_launcher_wait(updates: c_int, timeout_ms: c_int, uri: [*]u8, progress: *f64, progress_visible: *c_int, count: *c_longlong, count_visible: *c_int, urgent: *c_int) c_int;
