# Live Gaussian scopes

`ui.gaussian` prepares immutable Q24 kernels explicitly. A visual scope records
its body once, captures the declared source rectangle on transparent storage,
filters horizontally and vertically, then composites through the saved parent
clip, mask and opacity. Hit testing, focus, caret and `Space` geometry keep
their existing parent bounds. This API is separate from the existing f64
Gaussian image processor; its quantization is an explicit different contract.

```zig
const bank = try ui.gaussian.Bank.create(allocator, app.owner, .{});
const kernel = try bank.prepare(.{ .spec = .{ .sigma = 2, .scale = size.scale } });
try context.prepareGaussianWorkspace(allocator, .{
    .layers = .{ .size = size, .max_depth = 3 },
    .source_size = .{ .width = 320, .height = 200 },
    .max_radius = 16,
});
// Inside the ordinary draw callback:
try frame.gaussianScope(bounds, try kernel.view(), .{ .opacity = 192 }, state, drawSubtree);
```

The body has signature `fn (*anyopaque, *ui.Frame) anyerror!void`. A failed or
unbalanced body rolls back its commands, resource pins and Frame stacks; the
Frame retains the error. `endGroup` cannot close a Gaussian scope. Scope depth
shares the existing bounded group/transform stack.

For an offscreen owner, use the separate explicit constructor
`Surface.createGaussian(app_or_domain, allocator, ordinary_options, filter_options)`.
Its filter options contain `source_size`, `max_radius` and `filter_samples`.
Ordinary `Surface.create` uses a distinct compile-time implementation and does
not call the optional GPU filter factory. A standalone `commands.Buffer` binds
a caller-owned `FilterStorage`, records `beginGaussian` / `endGaussian`, and
releases its pins on reset. Prepared renderers accept that same buffer.

Bounds describe a conservative source extent. Capture rounds its physical
edges outward to integer texels and adds a transparent halo of `radius` texels.
Bounds themselves are not a fractional shape mask. Use an explicit child clip
when a precise fractional source crop is needed. The parent visual clip is
suspended during capture; child clips start in the source's visual domain.
`Frame.clipBounds` and geometric references still intersect the real parent.
The halo is part of the final filtered output and can influence pixels within
the parent clip even when its source lies outside that clip.

Sigma must be finite and nonnegative, preparation scale is in `[1/16, 16]`,
and `ceil(3 * sigma * scale)` is at most 128. Radius zero uses ordinary visual
isolation without Gaussian workspace, kernel pin, scratch, shader or taps.
Ordinary group capture and compositing still have their usual cost.

Preparation uses f64 normalized weights, center parity repair and symmetric
pair largest-remainder allocation. All coefficients are nonnegative, symmetric,
and sum exactly to `2^24`; each coefficient's absolute error is less than
`1/2^24`. Every pass accumulates premultiplied byte channels, adds `2^23` once
after the full sum, then shifts 24 bits. Missing samples are transparent black.
There is no edge clamp, per-tap rounding or hidden downsampling. The integer
sum is bounded by `255 * 2^24`, so CPU and shader uint accumulators fit in u32.

Kernel views borrow their immutable descriptor and matching lease. Their
owners must outlive all view use. Buffers pin each distinct kernel once;
`kernel.close()` returns `ResourceInUse` while pinned. A bank remains busy
until its last kernel closes. Allocation, cancellation and budget failures do
not publish a candidate. Caller allocator contexts outlive their last resource.

Workspace preparation charges the old owner, candidate software/GPU planes,
halo, one shared scratch plane, filter metadata and resource table before
allocation. Filter tap work and clear/draw/composite work have separate bounded
limits. Replay preflights the complete buffer before clearing a front or work
plane. Normal draw recording/replay does not create a worker, decode an image,
compile a shader, read back GPU pixels or allocate project-owned filter memory.
`releaseGaussianWorkspace` releases filter scratch/program/metadata while
retaining ordinary layer storage and accepted geometric references.

The optional GPU program is generated offline and prepared explicitly. It uses
integer texel loads and two prepared render targets. Unsupported precision,
capacity or unavailable filter resources use the existing typed whole-buffer
software fallback policy; a GPU-only texture can prevent software fallback.
Device loss revokes readiness and requires explicit preparation again. A live
Context calls `prepareGaussianWorkspace` again; an offscreen owner is closed
and recreated with `createGaussian` after its domain is recreated.

Gaussian adds one nullable pointer to Buffer and one to Context. Actual x64
measurements keep Command32, GroupCommand28, Frame928 and Input45192 unchanged;
Buffer grows143480→143488. Gaussian alone adds16 bytes to Context: the tested
Linux configuration is194752, and the Windows configuration before an
independent recipient callback change is250304. The final Windows Context is
250312, including that separate8-byte callback. These are declaration sizes,
not process memory or timing measurements. Native layer owners add one optional
pointer; filter paths allocate the separate owner and scratch only when prepared.
An opt-in resource table is784 bytes, Context workspace metadata864, View24,
immutable kernel1040, and Capture/Capacity24 each. Ordinary offscreen Options
remain unchanged; their internal State carries optional filter bookkeeping.
Ordinary groups incur a cold filter-slot test. No Gaussian tap, scratch, shader
or filter-owner allocation occurs on an unprepared normal path.

Debug and ReleaseSafe checks passed on Linux Cairo and Windows GDI, hardware
D3D11 and WARP. Independent literal Q24 pixel oracles cover scales1/1.5/2,
outside-parent influence, child clipping, masks, opacity, transparent edges and
zero sigma. One reflected raster-scope case independently reverses texel-center
coordinates. Warm replay preserves native creation counts; capacity rejection
preserves stats/front, and final Snapshot/Texture ownership survives Surface
closure. Allocation sweeps, native plane/program failures, device loss and
explicit re-creation also passed with final resources zero.

Real hidden Windows Context paints passed for both hardware and WARP at their
actual180×72 physical size and1.5 scale: a subtree callback runs once, failed
preparation preserves the front, and a rejected precision case replays the same
complete Buffer in software once. Context release and final-free closure guards
passed. The geometric Space/clip isolation and raster-stack restoration have
separate pure regressions. Ordinary Surface constructor binaries contain neither
Gaussian shader; explicit preparation binaries contain both, in both optimizations.
These are affected-scope runtime and ownership checks, not visual-quality or
performance results. The next integrated full check is recorded separately.
