# Transparent groups and frame workspaces

Transparent groups are opt-in. `Context.prepareLayers(allocator, options)` reserves bounded front/work/group planes outside paint; ordinary contexts do not allocate these planes. The prepared workspace is mutable renderer storage, not a retained image or an exportable immutable texture. General retained offscreen composition and arbitrary window transparency are separate capabilities.

```zig
try context.prepareLayers(allocator, .{
    .size = physical_size,
    .max_depth = 2,
    .bytes = 64 * 1024 * 1024,
    .total_bytes = 64 * 1024 * 1024,
});
// Record during draw, then close every group in the same frame.
try frame.beginGroup(bounds, .{ .opacity = 128 });
frame.roundedRect(first, 8, Color.rgb(0xff0000));
frame.roundedRect(second, 8, Color.rgb(0x0000ff));
try frame.endGroup();
```

Prepare again during the explicit resize/DPI update stage, before paint, using the new physical size and scale. A mismatched paint returns `LayersRequired`; it never resizes a workspace inside replay. `releaseLayers()` drops reusable group/work storage and retains the software committed front as the ordinary opaque front. Context resource operations require an attached owner-thread window and return `Busy` during draw. Release/prepare cancels a pending borrowed GPU ready watch before changing storage. Close releases the workspace after the current native callback is safe to detach.

## Recording and compositing

`Frame.beginGroup(bounds, layers.Group)` and `endGroup()` record bounded commands. Bounds are DIPs in the same coordinate system as ordinary drawing; a group does not establish a new coordinate origin. Frame offsets translate group bounds and mask origins. Maximum depth is four; each workspace chooses a smaller limit if desired. The frame has at most 2,048 commands, 32 total clips, and 32 shared coverage views. An end requires all clips opened inside that group to have been popped, and a child cannot pop a parent clip. Capacity, geometry and pin failures do not partially append commands.

A group starts transparent. All primitives preserve premultiplied alpha, including shapes, gradients, images, A8 coverage, prepared shaped text and grayscale legacy labels. Overlapping children first combine within that transparent plane. Group opacity applies once to the resulting premultiplied color and alpha before source-over onto its parent. It is not equivalent to assigning opacity independently to each child. Colors follow the existing encoded RGB convention; this API does not introduce linear-light blending.

The intersection of the group's bounds and the parent's exact rectangular clip applies once at the final composite. Only their integer work bounding box limits clearing and child work. Child clips operate inside that group and are restored on return. `Frame.clipBounds()` retains the full geometric intersection for widget hit regions and semantics, including ancestor group bounds; opacity and arbitrary mask texels do not silently change business input eligibility. Repeated groups at the same depth reuse preallocated storage. GPU replay flushes earlier consumers before target reuse; it does not allocate another target or synchronously wait for the GPU. Native edge antialiasing may differ, as with ordinary shapes; interior alpha, stop and compositing semantics remain the same.

An optional `Group.mask` borrows an immutable `CoverageView`, with `mask_origin` in DIPs. The mask must match the workspace scale and must be explicitly uploaded for Cairo/GPU. Its original CPU identity and pixels are unchanged. The frame deduplicates/pins the mask through the existing coverage resource table until replay finishes or aborts. Native residency has its separate lease pin and shared image/A8 slot and byte budget. Outside mask texels are transparent; bilinear sampling includes the explicit GPU transparent border prepared by coverage upload. Mask alpha multiplies group opacity and final clip coverage.

## Ownership and failure

Context owns both backend workspaces. It validates all per-backend and aggregate budgets before allocating a candidate. Both software and GPU candidates must succeed before either replaces its old workspace. A failed candidate releases every partial native object and keeps the previous workspace; real device loss can invalidate GPU device objects, as in the ordinary renderer.

Each paint clears an opaque white work plane once. Children use transparent group planes. Replay writes work, not the committed front. Successful native end/presentation swaps front/work; input hit/focus state and the native accessibility snapshot are committed only after successful rendering. Recording/preflight/replay errors, unbalanced groups, failed end and deferred GPU presentation discard pending input records and leave the committed front and previously published semantics in place. Accessibility publication itself retains its existing diagnostic failure boundary after rendering; it cannot roll back a frame already presented.

A business draw callback runs once. GPU failure replays the same bounded command buffer through the prepared software renderer. A successful fallback commits that software frame and input state. `PresentationBusy` keeps the previous GPU frame and registers the existing one-shot native ready wait; it does not switch to GDI or publish the unpresented frame's input state. Missing workspace is checked before replay touches an ordinary front. Device recreation explicitly rebuilds the bounded GPU workspace and resident resources and increments restoration statistics; a removed device cannot promise retention of its lost physical display image.

No renderer destructor callback runs through a group command. Frame reset releases temporary resource pins on success, failure, deferred presentation and close. Raw renderers expose the same explicit prepare/begin/replay/end/abort contract; callers must keep all borrowed resources alive and perform operations on the main thread. An open raw group can be inspected only by integration-test readback, not exported as an owning resource.

## Budgets and costs

`Options.size` is physical width/height plus scale. `bytes` limits each backend's workspace pixels. `total_bytes` limits Context's software plus enabled GPU workspace before either candidate allocates. Defaults are 64 MiB per backend and 64 MiB aggregate; maximum aggregate is 256 MiB. The per-plane size is width * height * 4, with checked surface dimension/byte limits before native calls.

| Backend | Reserved planes for depth D | Extra native resources |
| --- | --- | --- |
| GDI, grayscale labels | D + 3 | DC/DIB pairs, shared ordinary font and grayscale font |
| GDI, labels disabled | D + 2 | DC/DIB pairs and ordinary font |
| Cairo | D + 2 | Context/surface/pattern per plane, one layout/font |
| GPU | D + 2 | Premultiplied target bitmaps, one group bitmap brush per depth |

These counts include a workspace front, a work plane and D group planes. GDI's optional extra plane is reusable grayscale glyph scratch. At 1280 x 720 and depth two, GDI reserves 18,432,000 pixel bytes and GPU 14,745,600; together 33,177,600. Doubling both physical dimensions multiplies these costs by four. GPU swapchain buffers, native object metadata, driver allocations and the independent image/A8 residency budget are outside this workspace pixel budget.

`Context.layerStats()` lists software and optional GPU stats, `current_bytes` for active workspaces, `ordinary_front_bytes` for the retained normal software front when layers are disabled, and `candidate_peak_bytes`. The latter records the maximum bounded preparation reservation: old owned fronts/workspaces plus all new candidates. A native failure may occur before the reservation is fully allocated; it is not a process memory profiler. Each backend reports its own preparation reservation, pixel bytes, fixed metadata, native object creations/restores, clears/composites and committed/aborted frames. Temporary old plus new workspace reservation is bounded by 512 MiB. Metadata and real native allocation peaks are additional and platform dependent.

Preparation creates native objects and GDI grayscale font/scratch explicitly. Warm group replay creates no adapter-owned native objects and allocates no Zig storage. Clears, rectangular CPU alpha composition, masks and GPU target switches still cost time proportional to the actual clipped area and recorded work. GDI uses row fills for fully covered opaque pixels and integer premultiplied composition for complete unmasked pixels; fractional edges retain the scalar coverage calculation. Default opaque drawing retains its existing path. Legacy labels retain their existing native text-shaping costs; use explicit prepared shaped layouts when shaping must stay outside paint. `legacy_text = .disabled` omits GDI glyph scratch and rejects legacy text commands throughout that workspace.

## Verification

`zig build smoke-layers -Dgpu=true -Daccessibility=true` checks hidden GDI, hardware and WARP targets; Linux runs the same software fixture through Cairo/Pango. It covers three scales, overlapping alpha, same-depth reuse, opaque and transparent colors, prepared mixed-direction text, grayscale labels, images, alpha gradients, masks with fractional origins, fractional parent clips (including coincident group edges), partial native candidate failure, allocator failure, retained front after discard/Busy, device restoration, aggregate budgets, close and ready-watch teardown. Context tests retain old hit/semantic identities through failed/deferred frames and publish the replacement only after successful end. Native resource counts and owned text references return to zero; repeated warmed GDI process handle counts remain stable.

`benchmark-layers` separately reports explicit prepare median9, warm replay median9 x 3, end/submission CPU time, accepted ends and object stability for ordinary, workspace and nested-group scenes at 1x/2x. GPU replay/end values are CPU recording/submission timings, not GPU execution or physical display latency. Actual measurements are recorded separately; these APIs make no sustained refresh-rate guarantee.

The local ReleaseSafe observation uses a 1280 x 720 DIP scene, page allocator, nine samples and sequential platform runs while other task agents paused compilation and native tests. Full environment, source hashes, command line, 24 result rows and timing boundaries are in [layers-performance.json](layers-performance.json). This fixture has solid/rounded shapes and two nested opacity groups; it does not measure text, image upload or masks.

| Backend | 1x ordinary / workspace / nested replay | 2x ordinary / workspace / nested replay |
| --- | --- | --- |
| GDI | 5.230 / 5.562 / 9.101 ms | 18.978 / 18.410 / 38.075 ms |
| Cairo | 0.209 / 0.204 / 0.996 ms | 0.728 / 0.772 / 3.862 ms |
| Hardware GPU, CPU recording | 0.0022 / 0.0031 / 0.1155 ms | 0.0020 / 0.0026 / 0.1623 ms |
| WARP, CPU recording | 0.0026 / 0.0025 / 0.0452 ms | 0.0018 / 0.0033 / 0.1519 ms |

End/submission CPU time and explicit preparation remain separate JSON fields. Every row accepted 9/9 ends and retained stable warm native object counts. The 2x nested GDI cost is above a 60 Hz frame interval even before other application work; the result supports explicit preparation and backend selection, not a universal refresh-rate claim.
