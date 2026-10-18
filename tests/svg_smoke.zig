const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const svg = @import("ziggurat_svg");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_live_image_objects() u32;
const scales = [_]f32{ 1, 1.5, 2 };
const background: u32 = 0x204060;
const source =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 24">
    \\<style>.accent {fill: currentColor} #arc {stroke: #f0a8 !important}</style>
    \\<defs><symbol id="dot" viewBox="0 0 8 8"><circle cx="4" cy="4" r="4" class="accent"/></symbol>
    \\<path id="clip-geometry" d="M.25 .25H31.75V23.75H.25Z M2 14H3V15H2Z"/>
    \\<clipPath id="clip" clip-rule="evenodd"><use href="#clip-geometry"/><circle cx="16" cy="12" r="2"/></clipPath>
    \\<mask id="fade" maskUnits="userSpaceOnUse" x=".25" y=".25" width="31.5" height="23.5" color-interpolation="linearRGB"><rect width="32" height="24" fill="#c0c0c0"/><g opacity=".5"><circle cx="8" cy="18" r="5" fill="white"/></g></mask>
    \\<radialGradient id="cone" gradientUnits="userSpaceOnUse" cx="24" cy="18" r="3" fx="30" fy="20" fr="1" spreadMethod="reflect"><stop stop-color="#0f08"/><stop offset=".5" stop-color="red"/><stop offset="1" stop-color="blue"/></radialGradient>
    \\<linearGradient id="shade"><stop stop-color="red"/><stop offset="1" stop-color="gold" stop-opacity=".5"/></linearGradient></defs>
    \\<g clip-path="url(#clip)" mask="url(#fade)"><g opacity=".5" fill="url(#shade)"><rect x="2" y="2" width="16" height="10" rx="2"/>
    \\<rect x="12" y="2" width="16" height="10" style="fill:blue"/></g>
    \\<use href="#dot" x="4" y="14" width="8" height="8"/>
    \\<path id="arc" d="M16 16Q24 10 30 20" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-dasharray="2 1"/>
    \\<rect x="19" y="14" width="12" height="9" fill="url(#cone)"/>
    \\</g></svg>
;
const own_mask_source =
    \\<svg viewBox="0 0 32 24"><style>#a{mask:url(#b)}</style><defs>
    \\<mask id="c" maskUnits="userSpaceOnUse" x=".25" y=".25" width="31.5" height="23.5" mask-type="alpha"><rect x=".25" y=".25" width="31.5" height="23.5" fill="white" fill-opacity=".5"/></mask>
    \\<mask id="b" mask="url(#c)" maskUnits="userSpaceOnUse" x="0" y="0" width="32" height="24" mask-type="alpha"><rect width="32" height="24" fill="white" fill-opacity=".5"/></mask>
    \\<mask id="a" opacity="0" display="none" maskUnits="userSpaceOnUse" x="0" y="0" width="32" height="24" mask-type="alpha"><rect width="32" height="24" fill="white" fill-opacity=".5"/></mask>
    \\</defs><rect width="32" height="24" fill="blue" mask="url(#a)"/></svg>
;
const radial_source =
    \\<svg viewBox="0 0 32 24"><defs>
    \\<radialGradient id="near" gradientUnits="userSpaceOnUse" cx="2" cy="1e-30" r="1" fx="1" fy="0"><stop stop-color="red"/><stop offset="1" stop-color="blue"/></radialGradient>
    \\<radialGradient id="red" gradientUnits="userSpaceOnUse" cx="2.5" cy="2.5" r="2" fx="4.5" fy="2.5" spreadMethod="repeat"><stop stop-color="red" stop-opacity="0"/><stop offset="1" stop-color="red"/></radialGradient>
    \\<radialGradient id="gray" gradientUnits="userSpaceOnUse" cx="2.5" cy="2.5" r="2" fx="4.5" fy="2.5" spreadMethod="reflect" color-interpolation="linearRGB"><stop stop-color="#808080" stop-opacity="0"/><stop offset="1" stop-color="#808080"/></radialGradient>
    \\</defs><rect width="2" height="2" transform="translate(4 4)" fill="url(#near)"/>
    \\<rect width="8" height="6" transform="translate(4 8)" fill="url(#red)"/>
    \\<rect width="8" height="6" transform="translate(18 8)" fill="url(#gray)"/></svg>
;
const non_scaling_source =
    \\<svg viewBox="0 0 32 24"><path d="M2 3H14" transform="scale(2)" fill="none" stroke="red" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>
;
const non_scaling_root_source =
    \\<svg viewBox="0 0 32 24" transform="matrix(1 0 .5 1 1 2)"><path d="M2 3H14" transform="scale(2)" fill="none" stroke="red" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>
;
const pattern_source = "<svg viewBox='0 0 32 24'><defs><pattern id='p' patternUnits='userSpaceOnUse' x='.5' y='.5' width='4' height='4'><rect width='4' height='4' fill='red' fill-opacity='.5'/><rect width='4' height='4' fill='blue' fill-opacity='.5'/></pattern></defs><rect width='32' height='24' fill='url(#p)' fill-opacity='.5'/></svg>";
const expanded_pattern_source = "<svg viewBox='0 0 32 24'><defs color='green'><pattern id='left' width='.5' height='1' patternContentUnits='objectBoundingBox'><rect width='.25' height='1' fill='red'/></pattern><pattern id='base' patternUnits='userSpaceOnUse' width='8' height='12' viewBox='10 20 8 8'><rect x='10' y='20' width='4' height='8' fill='currentColor'/></pattern><g color='blue'><pattern id='right' href='#base'><desc>cloned content</desc></pattern></g><pattern id='bottom' width='.5' height='1' viewBox='0 0 16 12' preserveAspectRatio='none'><rect width='16' height='12' fill='red' fill-opacity='.5'/><rect width='16' height='12' fill='blue' fill-opacity='.5'/></pattern></defs><rect width='16' height='12' fill='url(#left)'/><rect x='16' width='16' height='12' fill='url(#right)'/><rect y='12' width='32' height='12' fill='url(#bottom)' fill-opacity='.5'/></svg>";
const marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='12' markerHeight='8' viewBox='10 20 4 4' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red'/></marker></defs><path d='M8 12H20' fill='none' marker-end='url(#m)'/></svg>";
const stroke_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerWidth='6' markerHeight='4' viewBox='10 20 4 4' refX='11' refY='21'><rect x='9' y='19' width='6' height='6' fill='red'/></marker></defs><path d='M8 12H16' fill='none' stroke-width='2' marker-end='url(#m)'/></svg>";
const mid_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerWidth='6' markerHeight='4' viewBox='10 20 4 4' refX='11' refY='21' orient='auto'><rect x='9' y='19' width='6' height='6' fill='red'/></marker></defs><path d='M4 8L12 12L20 8L28 12' fill='none' stroke-width='2' marker-mid='url(#m)'/></svg>";
const closed_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='s' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='#00ff00' fill-opacity='.5019607843137255'/></marker></defs><polygon points='8,8 24,8 24,16 8,16' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'/></svg>";
const bezier_marker_definitions = "<marker id='s' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='red'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='blue'/></marker><marker id='unused'><rect width='3' height='3'/></marker>";
const quadratic_marker_source = "<svg viewBox='0 0 32 24'><defs>" ++ bezier_marker_definitions ++ "</defs><path d='M8 8Q24 8 24 16' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#s)' marker-mid='url(#unused)' marker-end='url(#e)'/></svg>";
const cubic_marker_source = "<svg viewBox='0 0 32 24'><defs>" ++ bezier_marker_definitions ++ "</defs><path d='M8 8C8 8 24 8 24 16' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#s)' marker-mid='url(#unused)' marker-end='url(#e)'/></svg>";
const arc_marker_source = "<svg viewBox='0 0 32 24'><defs>" ++ bezier_marker_definitions ++ "</defs><path d='M8 8A16 8 0 0 1 24 16' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#s)' marker-mid='url(#unused)' marker-end='url(#e)'/></svg>";
const mixed_arc_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red'/><rect x='4' width='4' height='4' fill='blue'/></marker></defs><path d='M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20H4' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>";
const closed_arc_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20H4C0 20 0 4 4 4Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const zero_line_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M4 8H12L12 8V16' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/><path d='M24 16H24H24H24' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const zero_close_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M8 8C16 8 0 8 8 8Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/><path d='M24 8A4 4 0 0 1 24 16A4 4 0 0 1 24 8Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const closed_zero_line_marker_source = "<svg viewBox='0 0 32 24'><defs><clipPath id='c'><rect x='8' y='4' width='8' height='8'/></clipPath><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M12 20H2V8H12H12Z' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)' clip-path='url(#c)'/><path d='M8 18H8Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/><path d='M24 18H24H24Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const mixed_curve_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='8' height='4' fill='red'/></marker></defs><path d='M4 4Q12 0 12 8C12 16 16 16 24 16H28' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/></svg>";
const closed_curve_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M12 12C4 4 12 -4 20 4Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const zero_polynomial_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M4 0Q12 0 12 8Q12 8 12 8Q12 8 20 8' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/><path d='M8 18Q8 18 8 18C8 18 8 18 8 18' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/><path d='M24 18C24 18 24 18 24 18' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const closed_zero_polynomial_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M8 18C-2 18 -2 6 8 6Q8 6 8 6Z' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/><path d='M24 6C24 14 24 -2 24 6Q24 6 24 6Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/><path d='M8 18Q8 18 8 18Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/><path d='M24 18Q24 18 24 18C24 18 24 18 24 18Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const zero_arc_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M4 0A8 8 0 0 1 12 8Q12 8 12 8H20' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/><path d='M8 18Q8 18 8 18C8 18 8 18 8 18' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/><path d='M24 18C24 18 24 18 24 18' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-end='url(#m)'/></svg>";
const closed_zero_arc_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M12 0A8 8 0 0 1 20 8Q20 8 20 8H4Q4 8 4 8V0Q4 0 4 0Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/><path d='M20 18A8 8 0 0 1 4 18Q4 18 4 18A8 8 0 0 1 20 18C20 18 20 18 20 18Z' fill='none' vector-effect='non-scaling-stroke' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const ClosedArcPaint = struct { x: f64, y: f64, axis: enum { right, down, left, up } };
const closed_arc_paints = [_]ClosedArcPaint{
    .{ .x = 12, .y = 0, .axis = .right },
    .{ .x = 20, .y = 8, .axis = .down },
    .{ .x = 20, .y = 8, .axis = .left },
    .{ .x = 4, .y = 8, .axis = .left },
    .{ .x = 4, .y = 8, .axis = .up },
    .{ .x = 4, .y = 0, .axis = .up },
    .{ .x = 4, .y = 0, .axis = .right },
    .{ .x = 12, .y = 0, .axis = .right },
    .{ .x = 20, .y = 18, .axis = .down },
    .{ .x = 4, .y = 18, .axis = .up },
    .{ .x = 4, .y = 18, .axis = .up },
    .{ .x = 20, .y = 18, .axis = .down },
    .{ .x = 20, .y = 18, .axis = .down },
    .{ .x = 20, .y = 18, .axis = .down },
};
const omitted_arc_marker_source = "<svg viewBox='0 0 32 24'><defs><marker id='m' markerUnits='userSpaceOnUse' markerWidth='8' markerHeight='4' refX='4' refY='2' orient='auto'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/><rect x='4' width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M4 0A8 8 0 0 1 12 8Q12 8 12 8A7 7 0 0 1 12 8H20A7 7 90 1 0 20 8' fill='none' vector-effect='non-scaling-stroke' marker-mid='url(#m)'/><path d='M8 18A7 7 0 0 1 8 18Q8 18 8 18A7 7 0 0 1 8 18C8 18 8 18 8 18A0 7 0 1 1 8 18' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/><path d='M24 18H24A0 7 0 0 1 24 18A7 0 90 1 0 24 18Q24 18 24 18A7 7 0 1 1 24 18A0 0 0 0 0 24 18C24 18 24 18 24 18' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>";
const unified_topology_source = "<svg viewBox='0 0 32 24'><defs><marker id='s' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red'/></marker><marker id='m' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='#00ff00' fill-opacity='.5019607843137255'/></marker><marker id='e' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue'/></marker><marker id='hs' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='red' fill-opacity='.5019607843137255'/></marker><marker id='he' markerUnits='userSpaceOnUse' markerWidth='4' markerHeight='4' refX='2' refY='2'><rect width='4' height='4' fill='blue' fill-opacity='.5019607843137255'/></marker></defs><path d='M4 4A7 7 0 0 1 4 4M12 4A7 7 0 0 1 12 4H16A7 7 0 0 1 16 4ZM4 12C12 12 -4 12 4 12A7 7 0 0 1 4 12ZM20 12A7 7 0 0 1 20 12H24A7 7 0 0 1 24 12' fill='none' marker-start='url(#s)' marker-mid='url(#m)' marker-end='url(#e)'/><path d='M28 20A4 4 0 0 1 28 20A4 4 0 0 1 28 20' fill='none' marker-start='url(#hs)' marker-end='url(#he)'/></svg>";
const host_stroke_source = "<svg viewBox='0 0 32 24'><defs><marker id='hm' markerWidth='4' markerHeight='2' refX='2' refY='1' orient='auto'><rect width='2' height='2' fill='red'/><rect x='2' width='2' height='2' fill='blue'/></marker><marker id='hr' markerWidth='4' markerHeight='2' refX='2' refY='1' orient='auto-start-reverse'><rect width='2' height='2' fill='red'/><rect x='2' width='2' height='2' fill='blue'/></marker><marker id='hf' markerWidth='4' markerHeight='2' refX='2' refY='1' orient='90'><rect width='2' height='2' fill='red'/><rect x='2' width='2' height='2' fill='blue'/></marker></defs><path d='M2 3H4' transform='scale(2)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/><path d='M2 3H4' transform='matrix(-2 0 0 2 32 0)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/><path d='M2 2H4' transform='matrix(0 2 -2 0 16 8)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hm)'/><path d='M2 8H4' transform='scale(2)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-start='url(#hr)'/><path d='M10 8H12' transform='scale(2)' fill='none' stroke-width='2' vector-effect='non-scaling-stroke' marker-end='url(#hf)'/></svg>";
const Fixture = enum { scene, own_mask, radial, non_scaling, non_scaling_root, pattern, expanded_pattern, markers, stroke_markers, mid_markers, closed_markers, quadratic_markers, cubic_markers, mixed_curve_markers, closed_curve_markers, arc_markers, mixed_arc_markers, closed_arc_markers, zero_line_markers, zero_close_markers, closed_zero_line_markers, zero_polynomial_markers, closed_zero_polynomial_markers, zero_arc_markers, closed_zero_arc_markers, omitted_arc_markers, unified_topology_markers, host_stroke_markers };
const Job = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    compositing: @FieldType(svg.PrepareOptions, "compositing"),
    fixture: Fixture,
    images: [3]?*svg.Prepared = @splat(null),
    failure: ?anyerror = null,
    fn run(self: *Job) void {
        self.prepare() catch |err| {
            self.failure = err;
        };
    }
    fn prepare(self: *Job) !void {
        errdefer self.close();
        const document = try svg.Document.parse(self.allocator, switch (self.fixture) {
            .scene => source,
            .own_mask => own_mask_source,
            .radial => radial_source,
            .non_scaling => non_scaling_source,
            .non_scaling_root => non_scaling_root_source,
            .pattern => pattern_source,
            .expanded_pattern => expanded_pattern_source,
            .markers => marker_source,
            .stroke_markers => stroke_marker_source,
            .mid_markers => mid_marker_source,
            .closed_markers => closed_marker_source,
            .quadratic_markers => quadratic_marker_source,
            .cubic_markers => cubic_marker_source,
            .arc_markers => arc_marker_source,
            .mixed_arc_markers => mixed_arc_marker_source,
            .closed_arc_markers => closed_arc_marker_source,
            .zero_line_markers => zero_line_marker_source,
            .zero_close_markers => zero_close_marker_source,
            .closed_zero_line_markers => closed_zero_line_marker_source,
            .zero_polynomial_markers => zero_polynomial_marker_source,
            .zero_arc_markers => zero_arc_marker_source,
            .closed_zero_arc_markers => closed_zero_arc_marker_source,
            .omitted_arc_markers => omitted_arc_marker_source,
            .unified_topology_markers => unified_topology_source,
            .host_stroke_markers => host_stroke_source,
            .closed_zero_polynomial_markers => closed_zero_polynomial_marker_source,
            .mixed_curve_markers => mixed_curve_marker_source,
            .closed_curve_markers => closed_curve_marker_source,
        }, .{});
        defer document.close() catch unreachable;
        for (scales, 0..) |scale, i| self.images[i] = try document.prepare(self.allocator, .{ .main_thread = self.main_thread, .width = physical(32, scale), .height = physical(24, scale), .current_color = .{ .g = 255 }, .compositing = self.compositing });
    }
    fn close(self: *Job) void {
        for (&self.images) |*image| if (image.*) |value| {
            // Main-thread failure may precede adoption of later DPI images.
            // Worker-side failure still closes directly on its current owner.
            if (std.Thread.getCurrentId() == self.main_thread) value.adopt() catch |err| switch (err) {
                error.AlreadyAdopted => {},
                else => unreachable,
            };
            value.close() catch unreachable;
            image.* = null;
        };
    }
};
fn physical(value: u32, scale: f32) u32 {
    return @intFromFloat(@as(f32, @floatFromInt(value)) * scale);
}
fn read(renderer: anytype, x: u32, y: u32) !u32 {
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) return renderer.readPixelForTest(x, y);
    if (builtin.os.tag == .windows) {
        const pixel = c.GetPixel(renderer.dc, @intCast(x), @intCast(y));
        if (pixel == c.CLR_INVALID) return error.ReadPixelFailed;
        return ((pixel & 255) << 16) | (pixel & 0xff00) | ((pixel >> 16) & 255);
    }
    return zlc_test_raw_pixel(renderer.native.?, x, y);
}
fn readFrame(renderer: anytype, width: u32, height: u32, pixels: []u32) !void {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) return;
    try renderer.readPixelsForTest(width, height, pixels);
    // Cross-check the batch's indexing and channel order with the independent
    // single-pixel API, without a synchronous GPU round trip for every pixel.
    for ([_][2]u32{ .{ 0, 0 }, .{ width - 1, 0 }, .{ width / 2, height / 2 }, .{ 0, height - 1 }, .{ width - 1, height - 1 } }) |point|
        try std.testing.expectEqual(try read(renderer, point[0], point[1]), pixels[@as(usize, point[1]) * width + point[0]]);
}
fn framePixel(renderer: anytype, pixels: []const u32, width: u32, x: u32, y: u32) !u32 {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) return read(renderer, x, y);
    return pixels[@as(usize, y) * width + x];
}
noinline fn verify(renderer: anytype, image: *svg.Prepared, scale: f32) !void {
    const width = physical(64, scale);
    const height = physical(48, scale);
    var storage: if (@TypeOf(renderer.*) == ui.SoftwareRenderer) [0]u32 else [128 * 96]u32 = undefined;
    const pixels = if (@TypeOf(renderer.*) == ui.SoftwareRenderer) storage[0..] else storage[0 .. @as(usize, width) * height];
    try readFrame(renderer, width, height, pixels);
    const view = try image.view();
    const level = view.levels[0];
    for (0..physical(48, scale)) |y| for (0..physical(64, scale)) |x| {
        var expected = background;
        const left = physical(8, scale);
        const top = physical(8, scale);
        if (x >= left and y >= top and x < left + level.width and y < top + level.height and x >= physical(10, scale)) {
            const pixel = level.pixels[(y - top) * level.stride + (x - left) * 4 ..][0..4];
            const inverse = 1 - @as(f64, @floatFromInt(pixel[3])) / 255;
            var channels: [3]u32 = undefined;
            for (0..3) |i| channels[i] = @intFromFloat(@round(@as(f64, @floatFromInt(pixel[i])) + @as(f64, @floatFromInt((background >> @as(u5, @intCast(i * 8))) & 255)) * inverse));
            expected = channels[0] | (channels[1] << 8) | (channels[2] << 16);
        }
        const actual = try framePixel(renderer, pixels, width, @intCast(x), @intCast(y));
        inline for ([_]u5{ 0, 8, 16 }) |shift| {
            if (@abs(@as(i32, @intCast((expected >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255))) > 3) {
                std.debug.print("SVG native pixel ({d},{d}) scale={d}, expected={x}, actual={x}\n", .{ x, y, scale, expected, actual });
                return error.SvgPixelMismatch;
            }
        }
    };
}
noinline fn verifyScaledStrokeReplay(renderer: anytype) !void {
    var storage: if (@TypeOf(renderer.*) == ui.SoftwareRenderer) [0]u32 else [128 * 96]u32 = undefined;
    try readFrame(renderer, 128, 96, &storage);
    for (0..96) |y| for (0..128) |x| {
        const expected: u32 = if (x >= 24 and x < 72 and y >= 26 and y < 30) 0xff0000 else background;
        try std.testing.expectEqual(expected, try framePixel(renderer, &storage, 128, @intCast(x), @intCast(y)));
    };
}
fn render(renderer: anytype, job: *Job, context: *anyopaque, window: ?*anyopaque) !void {
    for (job.images) |image| try renderer.uploadImage(try image.?.view());
    const initial = renderer.imageStats();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    for (scales, job.images) |scale, maybe| {
        const image = maybe.?;
        buffer.reset();
        try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 48 }, background);
        try buffer.pushClip(.{ .x = 10, .y = 8, .width = 30, .height = 24 });
        try buffer.image(.{ .x = 8, .y = 8, .width = 32, .height = 24 }, try image.view(), .{ .sampling = .nearest });
        try buffer.popClip();
        try buffer.finish();
        try std.testing.expectError(error.ResourceInUse, image.close());
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = physical(64, scale), .height = physical(48, scale), .scale = scale } };
        for (0..3) |_| {
            try renderer.begin(paint);
            try renderer.replayBuffer(&buffer);
            try verify(renderer, image, scale);
            if (@TypeOf(renderer.*) == ui.SoftwareRenderer) renderer.end(paint) else renderer.end() catch |err| {
                if (err != error.PresentationBusy) return err;
            };
        }
    }
    try std.testing.expectEqual(initial.native_creations, renderer.imageStats().native_creations);
    if (job.fixture == .non_scaling) {
        // Replaying the SAME 1x bitmap at 2x intentionally scales its pixels,
        // including the prepared stroke. Only another prepare applies the
        // SVG host-space stroke contract to a new output viewport.
        buffer.reset();
        try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 48 }, background);
        try buffer.image(.{ .x = 8, .y = 8, .width = 32, .height = 24 }, try job.images[0].?.view(), .{ .sampling = .nearest });
        try buffer.finish();
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = 128, .height = 96, .scale = 2 } };
        try renderer.begin(paint);
        try renderer.replayBuffer(&buffer);
        try verifyScaledStrokeReplay(renderer);
        if (@TypeOf(renderer.*) == ui.SoftwareRenderer) renderer.end(paint) else renderer.end() catch |err| {
            if (err != error.PresentationBusy) return err;
        };
        try std.testing.expectEqual(initial.native_creations, renderer.imageStats().native_creations);
        buffer.reset();
        try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 48 }, background);
        try buffer.pushClip(.{ .x = 10, .y = 8, .width = 30, .height = 24 });
        try buffer.image(.{ .x = 8, .y = 8, .width = 32, .height = 24 }, try job.images[2].?.view(), .{ .sampling = .nearest });
        try buffer.popClip();
        try buffer.finish();
    }
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) {
        const scale = scales[2];
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = physical(64, scale), .height = physical(48, scale), .scale = scale } };
        try renderer.begin(paint);
        try renderer.replayBuffer(&buffer);
        renderer.injectDeviceLoss();
        try std.testing.expectError(error.DeviceLost, renderer.end());
        try renderer.begin(paint);
        try renderer.replayBuffer(&buffer);
        try verify(renderer, job.images[2].?, scale);
        renderer.end() catch |err| {
            if (err != error.PresentationBusy) return err;
        };
        try std.testing.expect(renderer.imageStats().restores >= 3);
        const restored = renderer.imageStats().native_creations;
        try renderer.begin(paint);
        try renderer.replayBuffer(&buffer);
        renderer.end() catch |err| {
            if (err != error.PresentationBusy) return err;
        };
        try std.testing.expectEqual(restored, renderer.imageStats().native_creations);
    }
    buffer.reset();
    for (job.images) |image| _ = try renderer.releaseImage((try image.?.view()).identity);
    for (job.images) |image| try image.?.lease.ensureUnused();
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    const selected_name = std.process.getEnvVarOwned(allocator, "ZIGGURAT_SVG_FIXTURE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (selected_name) |name| allocator.free(name);
    const selected = if (selected_name) |name| std.meta.stringToEnum(Fixture, name) orelse return error.UnknownFixture else null;
    for ([_]@FieldType(svg.PrepareOptions, "compositing"){ .pixel, .sample_color }) |mode| {
        for (std.enums.values(Fixture)) |fixture| {
            if (selected) |only| if (fixture != only) continue;
            try runMode(allocator, mode, fixture);
        }
    }
}
fn runMode(allocator: std.mem.Allocator, mode: @FieldType(svg.PrepareOptions, "compositing"), fixture: Fixture) !void {
    var job: Job = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId(), .compositing = mode, .fixture = fixture };
    // Preparation finishes before any App/UI loop is created. Runtime clients
    // can use the same exclusive handoff through their explicit App.post.
    const thread = try std.Thread.spawn(.{}, Job.run, .{&job});
    thread.join();
    defer job.close();
    if (job.failure) |err| return err;
    for (job.images, scales) |image, scale| {
        try std.testing.expectError(error.WrongThread, image.?.view());
        try image.?.adopt();
        if (fixture == .expanded_pattern) {
            const level = (try image.?.view()).levels[0];
            for (0..level.height) |y| for (0..level.width) |x| {
                const expected: [4]u8 = if (y >= physical(12, scale))
                    .{ 64, 0, 32, 96 }
                else if (x < physical(16, scale) and x % physical(8, scale) < physical(4, scale))
                    .{ 0, 0, 255, 255 }
                else if (x >= physical(16, scale) and y >= physical(2, scale) and y < physical(10, scale) and (x - physical(16, scale)) % physical(8, scale) < physical(4, scale))
                    .{ 255, 0, 0, 255 }
                else
                    .{ 0, 0, 0, 0 };
                try std.testing.expectEqualSlices(u8, &expected, image.?.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .unified_topology_markers) {
            const level = (try image.?.view()).levels[0];
            // Literal roles, independently of the marker topology cursor:
            // global start,2/1 closed-line mids,3 loop mids,1 final-subpath
            // mid,global end,and a separate K0 start followed by end.
            for (0..level.height) |y| for (0..level.width) |x| {
                const top = y >= physical(2, scale) and y < physical(6, scale);
                const middle = y >= physical(10, scale) and y < physical(14, scale);
                const left = x >= physical(2, scale) and x < physical(6, scale);
                const expected: [4]u8 = if (top and left)
                    .{ 0, 0, 255, 255 }
                else if (top and x >= physical(10, scale) and x < physical(14, scale))
                    .{ 0, 192, 0, 192 }
                else if (top and x >= physical(14, scale) and x < physical(18, scale))
                    .{ 0, 128, 0, 128 }
                else if (middle and left)
                    (if (mode == .pixel) .{ 0, 224, 0, 224 } else .{ 0, 223, 0, 223 })
                else if (middle and x >= physical(18, scale) and x < physical(22, scale))
                    .{ 0, 128, 0, 128 }
                else if (middle and x >= physical(22, scale) and x < physical(26, scale))
                    .{ 255, 0, 0, 255 }
                else if (x >= physical(26, scale) and x < physical(30, scale) and y >= physical(18, scale) and y < physical(22, scale))
                    .{ 128, 0, 64, 192 }
                else
                    @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .host_stroke_markers) {
            const level = (try image.?.view()).levels[0];
            // Fresh prepare moves the centers with its viewport scale, while
            // NSS strokeWidth keeps these marker extents in host pixels.
            const x4 = physical(4, scale);
            const x8 = physical(8, scale);
            const x12 = physical(12, scale);
            const x24 = physical(24, scale);
            const y6 = physical(6, scale);
            const y16 = physical(16, scale);
            for (0..level.height) |y| for (0..level.width) |x| {
                const top = y >= y6 - 2 and y < y6 + 2;
                const horizontal_bottom = y >= y16 - 2 and y < y16 + 2;
                const vertical_left = x >= x12 - 2 and x < x12 + 2;
                const vertical_right = x >= x24 - 2 and x < x24 + 2;
                const red = (top and ((x >= x8 - 4 and x < x8) or (x >= x24 and x < x24 + 4))) or
                    ((vertical_left or vertical_right) and y >= y16 - 4 and y < y16) or
                    (horizontal_bottom and x >= x4 and x < x4 + 4);
                const blue = (top and ((x >= x8 and x < x8 + 4) or (x >= x24 - 4 and x < x24))) or
                    ((vertical_left or vertical_right) and y >= y16 and y < y16 + 4) or
                    (horizontal_bottom and x >= x4 - 4 and x < x4);
                try std.testing.expect(!(red and blue));
                const expected: [4]u8 = if (red) .{ 0, 0, 255, 255 } else if (blue) .{ 255, 0, 0, 255 } else @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .own_mask) {
            const level = (try image.?.view()).levels[0];
            const offset = physical(12, scale) * level.stride + physical(16, scale) * 4;
            // Three independently resolved .5 alpha masks:128 ->64 ->32.
            try std.testing.expectEqualSlices(u8, &.{ 32, 0, 0, 32 }, level.pixels[offset..][0..4]);
        }
        if (fixture == .stroke_markers) {
            const level = (try image.?.view()).levels[0];
            // V(ref)=(2,1); scale2 gives the reference offset(4,2).
            // Endpoint(16,12) places the6x4 viewport at(12,10), size12x8.
            for (0..level.height) |y| for (0..level.width) |x| {
                const inside = x >= physical(12, scale) and x < physical(24, scale) and y >= physical(10, scale) and y < physical(18, scale);
                const expected: [4]u8 = if (inside) .{ 0, 0, 255, 255 } else @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .mid_markers) {
            const level = (try image.?.view()).levels[0];
            // Both equal-angle bisectors point right. V(ref)=(2,1), scale2;
            // the two clipped viewports are[8,20)x[10,18) and[16,28)x[6,14).
            for (0..level.height) |y| for (0..level.width) |x| {
                const first = x >= physical(8, scale) and x < physical(20, scale) and y >= physical(10, scale) and y < physical(18, scale);
                const second = x >= physical(16, scale) and x < physical(28, scale) and y >= physical(6, scale) and y < physical(14, scale);
                try std.testing.expectEqualSlices(u8, if (first or second) &.{ 0, 0, 255, 255 } else &.{ 0, 0, 0, 0 }, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .closed_markers) {
            const level = (try image.?.view()).levels[0];
            // The first vertex carries red then green(alpha128/255 each).
            // All three other listed vertices, including the last, carry blue.
            for (0..level.height) |y| for (0..level.width) |x| {
                const first = x >= physical(6, scale) and x < physical(10, scale) and y >= physical(6, scale) and y < physical(10, scale);
                const right = x >= physical(22, scale) and x < physical(26, scale) and ((y >= physical(6, scale) and y < physical(10, scale)) or (y >= physical(14, scale) and y < physical(18, scale)));
                const last = x >= physical(6, scale) and x < physical(10, scale) and y >= physical(14, scale) and y < physical(18, scale);
                const expected: [4]u8 = if (first) .{ 0, 128, 64, 192 } else if (right or last) .{ 255, 0, 0, 255 } else @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .closed_curve_markers) {
            const level = (try image.?.view()).levels[0];
            // Z enters p0 from(-8,8),the curve leaves along(-8,-8):seam180.
            // At pn the curve enters along(8,8),then Z leaves(-8,8):mid90.
            // Two alpha128 markers overlap at p0;only one is at pn.
            for (0..level.height) |y| for (0..level.width) |x| {
                const seam = x >= physical(8, scale) and x < physical(16, scale) and y >= physical(10, scale) and y < physical(14, scale);
                const last = x >= physical(18, scale) and x < physical(22, scale) and y < physical(8, scale);
                const expected: [4]u8 = if (seam) (if (x < physical(12, scale)) .{ 192, 0, 0, 192 } else .{ 0, 0, 192, 192 }) else if (last) (if (y < physical(4, scale)) .{ 0, 0, 128, 128 } else .{ 128, 0, 0, 128 }) else @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .mixed_curve_markers) {
            const level = (try image.?.view()).levels[0];
            // Q end/C start both point down at(12,8);C end/L start point
            // right at(24,16). No control point or final(28,16) is a mid.
            for (0..level.height) |y| for (0..level.width) |x| {
                const first = x >= physical(10, scale) and x < physical(14, scale) and y >= physical(4, scale) and y < physical(12, scale);
                const second = x >= physical(20, scale) and x < physical(28, scale) and y >= physical(14, scale) and y < physical(18, scale);
                try std.testing.expectEqualSlices(u8, if (first or second) &.{ 0, 0, 255, 255 } else &.{ 0, 0, 0, 0 }, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .mixed_arc_markers) {
            const level = (try image.?.view()).levels[0];
            // Two consecutive quarter arcs share a down-facing tangent at
            // (20,12);the next A/L boundary at(12,20) faces left. No marker
            // exists at the center,start or final H endpoint.
            for (0..level.height) |y| for (0..level.width) |x| {
                const first = x >= physical(18, scale) and x < physical(22, scale) and y >= physical(8, scale) and y < physical(16, scale);
                const second = x >= physical(8, scale) and x < physical(16, scale) and y >= physical(18, scale) and y < physical(22, scale);
                const expected: [4]u8 = if (first) (if (y < physical(12, scale)) .{ 0, 0, 255, 255 } else .{ 255, 0, 0, 255 }) else if (second) (if (x < physical(12, scale)) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 }) else @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .closed_arc_markers) {
            const level = (try image.?.view()).levels[0];
            // The real closing line and first A both point right. Start/end
            // paint this seam twice;the four listed mids paint once each.
            for (0..level.height) |y| for (0..level.width) |x| {
                const seam = x >= physical(8, scale) and x < physical(16, scale) and y >= physical(2, scale) and y < physical(6, scale);
                const down = x >= physical(18, scale) and x < physical(22, scale) and y >= physical(8, scale) and y < physical(16, scale);
                const left = x < physical(16, scale) and y >= physical(18, scale) and y < physical(22, scale);
                const terminal = x < physical(8, scale) and y >= physical(2, scale) and y < physical(6, scale);
                const alpha: u8 = if (seam) 192 else if (down or left or terminal) 128 else 0;
                const red = if (seam) x < physical(12, scale) else if (down) y < physical(12, scale) else if (left) (if (x < physical(8, scale)) x >= physical(4, scale) else x >= physical(12, scale)) else x < physical(4, scale);
                const expected: [4]u8 = if (red) .{ 0, 0, alpha, alpha } else .{ alpha, 0, 0, alpha };
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .zero_close_markers) {
            const level = (try image.?.view()).levels[0];
            // Each zero Z retains three coincident roles at the start point.
            // The two-arc loop has a fourth original vertex facing left at
            // (24,16). Its final listed point still faces right,not an open
            // endpoint or an omitted mid. Three alpha128 paints yield224 in
            // pixel,223 in the lane mode;the isolated left palette stays128.
            for (0..level.height) |y| for (0..level.width) |x| {
                const cubic = x >= physical(4, scale) and x < physical(12, scale) and y >= physical(6, scale) and y < physical(10, scale);
                const arc = x >= physical(20, scale) and x < physical(28, scale) and y >= physical(6, scale) and y < physical(10, scale);
                const left = x >= physical(20, scale) and x < physical(28, scale) and y >= physical(14, scale) and y < physical(18, scale);
                const accumulated: u8 = if (mode == .pixel) 224 else 223;
                const alpha: u8 = if (cubic or arc) accumulated else if (left) 128 else 0;
                const red = if (cubic) x < physical(8, scale) else if (arc) x < physical(24, scale) else x >= physical(24, scale);
                const expected: [4]u8 = if (red) .{ 0, 0, alpha, alpha } else .{ alpha, 0, 0, alpha };
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .zero_polynomial_markers or fixture == .zero_arc_markers or fixture == .omitted_arc_markers) {
            const level = (try image.?.view()).levels[0];
            // Q or the quarter-circle A is right-out/down-in. Both raw mids
            // paint down then right,
            // which makes the overlap colors differ from the old zero-L case.
            for (0..level.height) |y| for (0..level.width) |x| {
                const right = x >= physical(8, scale) and x < physical(16, scale) and y >= physical(6, scale) and y < physical(10, scale);
                const down = x >= physical(10, scale) and x < physical(14, scale) and y >= physical(4, scale) and y < physical(12, scale);
                const three = x >= physical(4, scale) and x < physical(12, scale) and y >= physical(16, scale) and y < physical(20, scale);
                const two = x >= physical(20, scale) and x < physical(28, scale) and y >= physical(16, scale) and y < physical(20, scale);
                const right_red = x < physical(12, scale);
                const down_red = y < physical(8, scale);
                const alpha: u8 = if (three) (if (mode == .pixel) 224 else 223) else if (fixture == .omitted_arc_markers) (if (mode == .pixel) 240 else 239) else 192;
                const expected: [4]u8 = if (three or two)
                    (if (x < physical(if (three) 8 else 24, scale)) .{ 0, 0, alpha, alpha } else .{ alpha, 0, 0, alpha })
                else if (right and down)
                    (if (right_red and down_red) .{ 0, 0, 192, 192 } else if (!right_red and !down_red) .{ 192, 0, 0, 192 } else if (right_red) .{ 64, 0, 128, 192 } else .{ 128, 0, 64, 192 })
                else if (right or down)
                    (if (if (right) right_red else down_red) .{ 0, 0, 128, 128 } else .{ 128, 0, 0, 128 })
                else
                    @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .closed_zero_arc_markers) {
            const level = (try image.?.view()).levels[0];
            // Prescribed circle tangents and each original role,not the marker
            // helper. Rectangles are exact pixel boundaries at all three DPIs.
            for (0..level.height) |y| for (0..level.width) |x| {
                const px = (@as(f64, @floatFromInt(x)) + 0.5) / scale;
                const py = (@as(f64, @floatFromInt(y)) + 0.5) / scale;
                var quantized: [4]u16 = @splat(0);
                var lanes: [4]f64 = @splat(0);
                for (closed_arc_paints) |paint| {
                    const dx = px - paint.x;
                    const dy = py - paint.y;
                    const vertical = paint.axis == .down or paint.axis == .up;
                    const inside = if (vertical) dx >= -2 and dx < 2 and dy >= -4 and dy < 4 else dx >= -4 and dx < 4 and dy >= -2 and dy < 2;
                    if (!inside) continue;
                    const red = switch (paint.axis) {
                        .right => dx < 0,
                        .down => dy < 0,
                        .left => dx >= 0,
                        .up => dy >= 0,
                    };
                    const color: [4]u16 = if (red) .{ 0, 0, 128, 128 } else .{ 128, 0, 0, 128 };
                    for (color, 0..) |channel, i| {
                        quantized[i] = channel + (quantized[i] * 127 + 127) / 255;
                        lanes[i] = @as(f64, @floatFromInt(channel)) + lanes[i] * (127.0 / 255.0);
                    }
                }
                var expected: [4]u8 = undefined;
                for (&expected, 0..) |*channel, i| channel.* = if (mode == .pixel) @intCast(quantized[i]) else @intFromFloat(@round(lanes[i]));
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .closed_zero_polynomial_markers) {
            const level = (try image.?.view()).levels[0];
            // The first C is right-in before a constant Q and a down Z:
            // horizontal then vertical palettes. The same-end C at(24,6)
            // is nonconstant,down-out/down-in:all four roles stay vertical.
            // Constant Q+Z and Q+C+Z retain3/4 horizontal role paints below.
            for (0..level.height) |y| for (0..level.width) |x| {
                const right = x >= physical(4, scale) and x < physical(12, scale) and y >= physical(4, scale) and y < physical(8, scale);
                const down = x >= physical(6, scale) and x < physical(10, scale) and y >= physical(2, scale) and y < physical(10, scale);
                const loop = x >= physical(22, scale) and x < physical(26, scale) and y >= physical(2, scale) and y < physical(10, scale);
                const three = x >= physical(4, scale) and x < physical(12, scale) and y >= physical(16, scale) and y < physical(20, scale);
                const four = x >= physical(20, scale) and x < physical(28, scale) and y >= physical(16, scale) and y < physical(20, scale);
                const right_red = x < physical(8, scale);
                const down_red = y < physical(6, scale);
                const alpha: u8 = if (three) (if (mode == .pixel) 224 else 223) else if (mode == .pixel) 240 else 239;
                const expected: [4]u8 = if (loop)
                    (if (y < physical(6, scale)) .{ 0, 0, alpha, alpha } else .{ alpha, 0, 0, alpha })
                else if (three or four)
                    (if (x < physical(if (three) 8 else 24, scale)) .{ 0, 0, alpha, alpha } else .{ alpha, 0, 0, alpha })
                else if (right and down)
                    (if (right_red and down_red) .{ 0, 0, 192, 192 } else if (!right_red and !down_red) .{ 192, 0, 0, 192 } else if (down_red) .{ 64, 0, 128, 192 } else .{ 128, 0, 64, 192 })
                else if (right or down)
                    (if (if (right) right_red else down_red) .{ 0, 0, 128, 128 } else .{ 128, 0, 0, 128 })
                else
                    @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .closed_zero_line_markers) {
            const level = (try image.?.view()).levels[0];
            // Z itself supplies the later down anchor for the two raw mids
            // at(12,8). The earlier x2 mids cannot enter the target clip.
            // All-zero closed n1/n2 retain3/4 distinct positive-x paints.
            for (0..level.height) |y| for (0..level.width) |x| {
                const right = x >= physical(8, scale) and x < physical(16, scale) and y >= physical(6, scale) and y < physical(10, scale);
                const down = x >= physical(10, scale) and x < physical(14, scale) and y >= physical(4, scale) and y < physical(12, scale);
                const three = x >= physical(4, scale) and x < physical(12, scale) and y >= physical(16, scale) and y < physical(20, scale);
                const four = x >= physical(20, scale) and x < physical(28, scale) and y >= physical(16, scale) and y < physical(20, scale);
                const right_red = x < physical(12, scale);
                const down_red = y < physical(8, scale);
                const alpha: u8 = if (three) (if (mode == .pixel) 224 else 223) else if (mode == .pixel) 240 else 239;
                const expected: [4]u8 = if (three or four)
                    (if (x < physical(if (three) 8 else 24, scale)) .{ 0, 0, alpha, alpha } else .{ alpha, 0, 0, alpha })
                else if (right and down)
                    (if (right_red and down_red) .{ 0, 0, 192, 192 } else if (!right_red and !down_red) .{ 192, 0, 0, 192 } else if (down_red) .{ 64, 0, 128, 192 } else .{ 128, 0, 64, 192 })
                else if (right or down)
                    (if (if (right) right_red else down_red) .{ 0, 0, 128, 128 } else .{ 128, 0, 0, 128 })
                else
                    @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .zero_line_markers) {
            const level = (try image.?.view()).levels[0];
            // One internal zero contributes right then down palettes at(12,8).
            // The separate all-zero path paints four horizontal palettes at
            // (24,16),including both endpoints. Pixel rounds each paint to240;
            // the floating sample lane rounds its239.311... only at the end.
            for (0..level.height) |y| for (0..level.width) |x| {
                const right = x >= physical(8, scale) and x < physical(16, scale) and y >= physical(6, scale) and y < physical(10, scale);
                const down = x >= physical(10, scale) and x < physical(14, scale) and y >= physical(4, scale) and y < physical(12, scale);
                const all_zero = x >= physical(20, scale) and x < physical(28, scale) and y >= physical(14, scale) and y < physical(18, scale);
                const right_red = x < physical(12, scale);
                const down_red = y < physical(8, scale);
                const accumulated: u8 = if (mode == .pixel) 240 else 239;
                const expected: [4]u8 = if (all_zero)
                    (if (x < physical(24, scale)) .{ 0, 0, accumulated, accumulated } else .{ accumulated, 0, 0, accumulated })
                else if (right and down)
                    (if (right_red and down_red) .{ 0, 0, 192, 192 } else if (!right_red and !down_red) .{ 192, 0, 0, 192 } else if (down_red) .{ 64, 0, 128, 192 } else .{ 128, 0, 64, 192 })
                else if (right or down)
                    (if (if (right) right_red else down_red) .{ 0, 0, 128, 128 } else .{ 128, 0, 0, 128 })
                else
                    @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .quadratic_markers or fixture == .cubic_markers or fixture == .arc_markers) {
            const level = (try image.?.view()).levels[0];
            // Start tangent points right;end tangent points down,regardless
            // of the diagonal endpoint chord or the repeated first control.
            for (0..level.height) |y| for (0..level.width) |x| {
                const start = x >= physical(4, scale) and x < physical(12, scale) and y >= physical(6, scale) and y < physical(10, scale);
                const end = x >= physical(22, scale) and x < physical(26, scale) and y >= physical(12, scale) and y < physical(20, scale);
                const expected: [4]u8 = if (start) .{ 0, 0, 255, 255 } else if (end) .{ 255, 0, 0, 255 } else @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .markers) {
            const level = (try image.?.view()).levels[0];
            // V=(2x-18,2y-40), V(ref)=(4,2), endpoint=(20,12).
            // The marker viewport is therefore [16,28] x [10,18]. The
            // oversized rectangle covers it; no marker helper is reused.
            for (0..level.height) |y| for (0..level.width) |x| {
                const inside = x >= physical(16, scale) and x < physical(28, scale) and y >= physical(10, scale) and y < physical(18, scale);
                const expected: [4]u8 = if (inside) .{ 0, 0, 255, 255 } else @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .pattern) {
            const level = (try image.?.view()).levels[0];
            for (0..level.height) |y| for (0..level.width) |x| try std.testing.expectEqualSlices(u8, &.{ 64, 0, 32, 96 }, level.pixels[y * level.stride + x * 4 ..][0..4]);
        }
        if (fixture == .radial) {
            const level = (try image.?.view()).levels[0];
            for ([_]struct { x: u32, y: u32, pixel: [4]u8 }{
                .{ .x = 4, .y = 4, .pixel = .{ 0, 0, 0, 0 } },
                .{ .x = 10, .y = 10, .pixel = .{ 0, 0, 128, 128 } },
                .{ .x = 24, .y = 10, .pixel = .{ 64, 64, 64, 128 } },
            }) |point| {
                const offset = physical(point.y, scale) * level.stride + physical(point.x, scale) * 4;
                try std.testing.expectEqualSlices(u8, &point.pixel, level.pixels[offset..][0..4]);
            }
        }
        if (fixture == .non_scaling) {
            const level = (try image.?.view()).levels[0];
            for (0..level.height) |y| for (0..level.width) |x| {
                const inside = x >= physical(4, scale) and x < physical(28, scale) and (y == physical(6, scale) - 1 or y == physical(6, scale));
                const expected: [4]u8 = if (inside) .{ 0, 0, 255, 255 } else @splat(0);
                try std.testing.expectEqualSlices(u8, &expected, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
        if (fixture == .non_scaling_root) {
            const level = (try image.?.view()).levels[0];
            for (0..level.height) |y| for (0..level.width) |x| {
                var count: u16 = 0;
                for (0..4) |sy| for (0..4) |sx| {
                    const output_y = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4;
                    const output_x = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4;
                    const host_y = output_y - 2;
                    const host_x = output_x - 0.5 * host_y - 1;
                    if (host_x >= 4 * scale and host_x < 28 * scale and host_y >= 6 * scale - 1 and host_y < 6 * scale + 1) count += 1;
                };
                const alpha: u8 = @intCast((count * 255 + 8) / 16);
                try std.testing.expectEqualSlices(u8, &.{ 0, 0, alpha, alpha }, level.pixels[y * level.stride + x * 4 ..][0..4]);
            };
        }
    }
    if (builtin.os.tag == .windows) {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        {
            const hwnd = window.nativeHandle();
            const dc = c.GetDC(hwnd) orelse return error.CreateSurfaceFailed;
            defer _ = c.ReleaseDC(hwnd, dc);
            const before = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            {
                var renderer: ui.SoftwareRenderer = .{};
                defer renderer.deinit();
                try render(&renderer, &job, dc, hwnd);
            }
            try std.testing.expectEqual(before, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
            if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
                var renderer: ui.d3d11.Renderer = .{};
                try renderer.init(.{ .driver = driver });
                defer renderer.deinit();
                try render(&renderer, &job, dc, hwnd);
                renderer.deinit();
                try std.testing.expectEqual(0, ui.d3d11.globalResourceCount());
                std.debug.print("SVG {s}/{s}/{s}: prepared pixels, 3 DPI, clip, stable native creations and references=0\n", .{ @tagName(mode), @tagName(fixture), @tagName(driver) });
            };
        }
        _ = try window.destroy();
    } else {
        const surface = cairo_image_surface_create(0, 128, 96) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(context);
        var renderer: ui.SoftwareRenderer = .{};
        defer renderer.deinit();
        try render(&renderer, &job, context, null);
        renderer.deinit();
        try std.testing.expectEqual(0, zlc_test_live_image_objects());
    }
    std.debug.print("SVG {s}/{s}: worker prepare/owner handoff, source-independent snapshots, native replay and frame/residency pins passed\n", .{ @tagName(mode), @tagName(fixture) });
}
