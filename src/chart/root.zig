//! Charts without a look of their own: scales that map data onto a plot and
//! pick round ticks, a plot layout with axes around it, placement of bars,
//! points and rules, paths of lines, areas and pie slices, stacking,
//! downsampling of dense lines, legends, and a selection that the pointer
//! and the keyboard move.
//!
//! Positions along a plot are fractions of it, from 0 to 1: along x from its
//! left edge, and along y from its bottom up, the way values grow. Nothing
//! here allocates: ticks, paths, stacks and reductions are written into
//! caller-owned storage, so a chart redrawn every frame stays warm.
//! `ziggurat_chart_view` draws charts in declarative views.
const scale = @import("scale.zig");
const time = @import("time.zig");
const stacking = @import("stack.zig");
const shape = @import("shape.zig");
const downsample = @import("downsample.zig");
const plot = @import("plot.zig");

pub const Span = scale.Span;
pub const Tick = scale.Tick;
pub const max_label = scale.max_label;
pub const Format = scale.Format;
pub const Linear = scale.Linear;
pub const Band = scale.Band;
pub const TickValues = scale.TickValues;
pub const tickValues = scale.tickValues;
pub const extent = scale.extent;
pub const formatFixed = scale.formatFixed;

pub const Time = time.Time;
pub const TimeFormat = time.TimeFormat;
pub const Civil = time.Civil;
pub const fromCivil = time.fromCivil;
pub const toCivil = time.toCivil;
pub const formatTime = time.formatTime;

pub const Segment = stacking.Segment;
pub const Stacking = stacking.Stacking;
pub const stack = stacking.stack;

pub const Rect = shape.Rect;
pub const Point = shape.Point;
pub const Command = shape.Command;
pub const Path = shape.Path;
pub const Curve = shape.Curve;
pub const CurveSegment = shape.Segment;
pub const Slice = shape.Slice;
pub const x = shape.x;
pub const y = shape.y;
pub const curve = shape.curve;
pub const line = shape.line;
pub const area = shape.area;
pub const nearest = shape.nearest;
pub const pie = shape.pie;
pub const polar = shape.polar;
pub const sector = shape.sector;
pub const sliceAt = shape.sliceAt;

pub const Reduced = downsample.Reduced;
pub const minMax = downsample.minMax;

pub const Size = plot.Size;
pub const Measure = plot.Measure;
pub const Side = plot.Side;
pub const Axes = plot.Axes;
pub const Layout = plot.Layout;
pub const layout = plot.layout;
pub const rect = plot.rect;
pub const point = plot.point;
pub const ruleX = plot.ruleX;
pub const ruleY = plot.ruleY;
pub const Anchor = plot.Anchor;
pub const anchor = plot.anchor;
pub const LegendItem = plot.LegendItem;
pub const LegendSlot = plot.LegendSlot;
pub const LegendOptions = plot.LegendOptions;
pub const legend = plot.legend;
pub const Key = plot.Key;
pub const Change = plot.Change;
pub const Selection = plot.Selection;

test {
    _ = @import("tests.zig");
}
