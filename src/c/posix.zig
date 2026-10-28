//! libc declarations for POSIX dynamic loading, environment and descriptors.
pub const RTLD_LAZY: c_int = 0x0001;
pub const RTLD_NOW: c_int = 0x0002;
pub const RTLD_GLOBAL: c_int = 0x0100;
pub const RTLD_LOCAL: c_int = 0;

pub extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
pub extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
pub extern "c" fn dlclose(handle: ?*anyopaque) c_int;
pub extern "c" fn dlerror() ?[*:0]const u8;
pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern "c" fn unsetenv(name: [*:0]const u8) c_int;
pub extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
pub extern "c" fn pipe(fds: *[2]c_int) c_int;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn read(fd: c_int, buffer: ?*anyopaque, count: usize) isize;
pub extern "c" fn write(fd: c_int, buffer: ?*const anyopaque, count: usize) isize;
