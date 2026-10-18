# Affine raster scopes

`Context.prepareTransforms` explicitly prepares raster sources and committed coordinate snapshots. The Frame/input/IME/accessibility contract is documented in [affine.md](affine.md). This document describes the renderer half. Ordinary contexts and ordinary `prepareLayers` do not allocate a transform table or larger source pool.

```zig
try context.prepareTransforms(allocator, .{
    .layers = .{ .size = physical_window_size, .max_depth = 4 },
    .source_size = .{ .width = 512, .height = 256 },
    .render_work = 128 * 1024 * 1024,
});
```

A transform scope first renders its children into a transparent, local raster source at the workspace DPI. Local `(0,0)` is the source origin. Its explicit DIP extent limits child drawing; it is independent of the parent window extent. The completed premultiplied BGRA source is bilinearly sampled through the forward affine matrix into its parent. This is a raster-group operation: it does not reshape fonts at the transformed size, turn images into vector geometry, or provide area filtering for minification.

The public affine value is f64. Recording canonicalizes all six coefficients once to representable f32 values, stores those exact values as f64, and uses that same forward transform for committed input geometry. Source dimensions remain f32 DIP, with physical dimensions `ceil(source * scale)`. Invalid, singular, excessively conditioned, nonfinite or unrepresentable source geometry fails before recording/native replay. Source dimensions including the guards must fit the existing surface limits; the transform validates the padded source quad too. Native rasterization still has its own finite coordinate/interpolation precision; canonical coefficients do not imply bit-identical arithmetic on every backend.

## Command and source ownership

`begin_transform` contains one u8 slot; `end_transform` contains no descriptor. `commands.TransformStorage` has 64 value descriptors and is supplied explicitly by the caller. `Buffer` holds only an optional borrow. Bind empty storage to an empty buffer with `bindTransformStorage`; set `storage.scale` to the actual workspace scale first. A second Buffer cannot bind the same storage concurrently. `Buffer.reset` clears the table and binding, including error/close paths. The storage address must stay stable until reset. It contains no native handles or owning destructors.

`layers.NativeTransform` is a checked, 64-byte descriptor: six f64 coefficients, two f32 source dimensions and two u32 physical dimensions. Both Zig and C assert the layout. Repeated equal descriptors share a slot. Capacity, invalid geometry and stack failures do not partially publish a descriptor or command. Groups and transforms share the configured stack, with a hard maximum depth of four; scopes must close with the matching kind and all their own clips balanced. A child cannot pop an ancestor clip.

The Context owns the recording table in its explicitly allocated transform workspace. CPU and GPU offscreen resources opt in with `Options.transform_source`; each allocates its own capture table at construction and includes it in metadata accounting. Preflight validates the entire source batch before output allocation or native drawing. Capture copies descriptors and takes independent resource pins before any foreign allocator callback. Resetting/reusing the source buffer or table in such a callback cannot change the captured frame. Source and destination table aliases are rejected. No source buffer pointer survives render.

## Pool and compositing

The front and work planes retain the physical window/output size. Each shared depth plane uses the componentwise maximum of the window size and maximum physical source size **plus two pixels**. GDI's optional grayscale glyph scratch uses that same pool size. Thus a group inside a source larger than the window can draw the complete source. Group and transform nesting do not allocate another target during replay.

Every transform reserves one transparent physical texel on all four sides of its used source. The native target origin shifts by exactly one physical pixel, while business coordinates remain unchanged. Starting a source clears its complete used rectangle including guards. The sampled rectangle includes the guard; replay does not clip a second time at the logical fractional source boundary. Old pixels elsewhere in the larger reusable pool are outside that sampled rectangle. This preserves transparent extension at nonzero source edges and fractional positioning.

Parent clip coverage applies at final composition only. Child clips belong to the local source; groups continue to apply their own opacity/mask after their children combine. D2D draws the padded bitmap with aliased primitive edges: alpha is already bilinearly filtered against transparent guard texels, and another primitive edge coverage would attenuate it twice. This does not change the separately antialiased parent clip. Repeated same-depth scopes reuse the same targets. D2D flushes the earlier consumer before target reuse; this submits ordered work, without a fence or blocking GPU wait.

GDI and Cairo use the same bounded f64 inverse sampler at transform completion. Cairo first flushes its child/parent image surfaces, then lends their actual pixels and strides to the synchronous sampler. The borrow does not pop depth or change clip state. All fallible sampling geometry is checked before the first write; completion marks only the tight visited rectangle dirty, then restores the parent. A failure uses the existing frame abort and retained front. No borrowed plane survives the call, no callback runs during sampling, and pool pixels outside the used source plus its guards are never read. Ordinary non-transform Cairo replay is unchanged. Normal replay does not allocate Zig storage, create a target/pattern, decode an image, upload a resource, or shape prepared text.

Image/A8 residency remains separate and explicit. A prepared glyph still borrows its original native Layout and prepared coverage under the existing Lease. Transforming it changes raster sampling, not shaping. Legacy label rendering keeps its existing per-call native text cost and grayscale transparent-target policy.

Preparation creates complete candidates. Same-size/same-DPI reconfiguration copies an available retained committed front before replacing the old workspace. It does not treat a discarded flip buffer as a reliable retained image. A failed candidate leaves the old workspace in place; failed replay/end keeps its committed front and the accepted coordinate snapshot. GPU device loss invalidates the lost native payloads, so physical visibility cannot be promised during loss. Explicit recreation rebuilds the bounded pool; a later successful frame establishes a new front. A business draw is never rerun to recover a backend.

## Budgets and work

Let `W` be window pixel bytes, `P` the guarded maximum pool pixel bytes and `D` the configured combined depth. GDI reserves `2W + (D+1)P` with grayscale labels, or `2W + DP` with labels disabled. Cairo and D2D reserve `2W + DP`. Ordinary layer plans retain their previous equal-plane formula. Backend `bytes` and Context aggregate checks run before candidate allocation; explicit reconfiguration also accounts for the old-plus-candidate reservation and Context geometry metadata. Backend fixed structures/native object metadata are reported separately; driver memory, native glyph caches and allocator headers are not represented by the pixel counts.

`render_work` defaults to 128 Mi plane visits and is limited to 512 Mi for transform-enabled resources. It is a conservative whole-window/pool bound per command, including clear/composite and legacy glyph passes. It is checked before replay and is not a GPU instruction count, shaping-time limit or display-latency guarantee. Smaller clipped rectangles reduce actual work. Device restoration and explicit preparation can allocate bounded native storage; ordinary cache-hit replay does not perform those operations.

## Sampling precision and validation

The semantic source is a premultiplied BGRA8 raster at each scope boundary. Each nested scope introduces another sampling and byte-quantization stage; nesting is not equivalent to multiplying matrices and sampling the original image once. Color interpolation is in the existing encoded RGB convention. Native bilinear arithmetic can differ in low bits.

The software sampler rounds each premultiplied BGRA8 channel after four f64-weighted taps. An exact physical signed permutation can use one tap: physical translation products must be exact, scale is limited to [.25,8], bounded translation/origin terms prevent large cancellation, and the final half-texel phase must be integral. Interior contiguous rows use eight packed source-over operations; opaque copies are selected from the actual eight pixel alphas, never inferred from a scope. Fractional clip edges retain scalar coverage. General full-coverage batches have eight fixed sample pixels and use the same packed blending. Four-channel interpolation preserves the scalar tap order; rounding compares the fractional part with .5, including its immediate floating-point neighbors. These paths have fixed stack scratch and no heap allocation.

The former native Cairo bitmap-quad path lost a subpixel source under a 1/4096 scale and reported an error for a large shear. The shared sampler keeps those valid software inputs. It does not rely on Cairo primitive clip quantization or native bitmap inverse limits. Cairo still draws the source's ordinary shapes, text and groups through its existing implementations; replacing transform completion does not make all source rasterization identical across backends.

GPU eligibility is checked for the whole captured Buffer before any command drawing. The fixed four-level walk checks every actual padded quad, cumulative logical parent, f32 evaluation range and nearest-1/256-physical-pixel vertex snapping. Each stage's conservative source-coordinate L1 contribution and their chain sum must fit 1/256 texel; matrix coefficients, inverse norm and physical magnitudes have additional limits. Exact aligned .125/.5 minification remains supported, while tiny or large-shear cases return `UnsupportedTransformPrecision` with native error code zero. This is a tested supported profile, not a proof of every driver's internal arithmetic.

Some ordinary noninteger nested matrices also exceed that conservative chain bound. Context uses the same recorded Buffer in software, without running business draw again; this can cost more CPU than the former forced GPU path. A direct GPU/offscreen call returns the precision error before drawing and retains the old front. GPU textures have no implicit software fallback. Tightening the reachable-domain error analysis is separate work; a previously passing image does not remove the whole-frame safety gate.

`smoke-affine-renderer` uses an independent f128 inverse/analytic source-cell oracle for translation, reflection, right-angle and oblique rotation, shear and nonuniform scale. Software and eligible GPU cases retain the same strict checks; constant-color and separate half-texel/fractional-source/clip oracles keep their narrower checks. Each nested stage is checked against its actual previous BGRA8 raster. A merged one-stage transform produces different pixels, confirming that the fixture exercises repeated filtering. These per-stage checks do not assert a single whole-scene error bound.

The latter case also retains a D2D edge regression: source `4×4` DIP, scale `2`, matrix `{xx=.8,xy=.25,yy=1.1,x0=1.2,y0=.7}`, pixel `(3,7)`. Primitive edge AA produced BGRA `0x20000020` against the center-sampling result `0x24000024`; disabling that additional bitmap-quad coverage restores the existing GPU tolerance without increasing the guard or weakening parent clip checks.

The same hidden/offscreen fixture exercises three DPI values, larger-than-window sources with groups, nested target reuse, independent image/A8/mask/hard-gradient inputs, prepared glyphs against the same backend's untransformed native source, unchanged shaping statistics, all Zig allocation failures, source-buffer reset during allocator reentry, preflight front preservation, GPU loss/recreation and native resource balance. GPU readback is test-only; production replay never performs it. These checks establish implementation and lifecycle behavior, not visual quality or a frame-rate guarantee.

## Reproducible Cairo cost comparison

The optional Linux `zig build benchmark-affine-cairo -Doptimize=ReleaseSafe` tool compares the shared sampler with this project's previous native Cairo transform-completion path. The native baseline exists only in the tool; production always uses the shared sampler. Default test/check and applications do not depend on this benchmark. `-- --pilot --matrix quarter --samples 7` selects a short run. `--help` lists the supported filters.

The full run has 378 scenarios: physical sizes 64×64, 512×512 and 1920×1080; scales 1/1.5/2; identity, integer translation, .25-pixel translation, .5× scale, 2× scale, oblique and shear matrices; depths 1/2/4; source alpha 255/128. Each scenario has four warmup pairs and 21 measured pairs. Construction, source filling and frame preparation are outside timing. Output reports paired completion median/p95, visits, and separate flush/borrow/draw/finish times. It checks stable adapter native-object creation counts and zero adapter resources after destruction. These counters do not establish zero internal Cairo allocation. Results measure CPU composition, not full frame cost, display latency or visual quality.

An isolated ReleaseSafe run on a Ryzen 7 9800X3D, WSL Ubuntu 24.04, Cairo 1.18.0 and Pixman 0.42.2 produced the following 1920×1080, scale-1, depth-1 medians. Times are milliseconds; each cell shows opaque / alpha-128 input.

| Matrix | Previous native path | Shared sampler | Sampler/native ratio |
| --- | --- | --- | --- |
| Identity | .304 / .839 | .292 / .800 | .96 / .95 |
| Integer translation | .322 / .842 | .276 / .723 | .86 / .86 |
| .25 translation | 1.695 / 2.751 | 7.408 / 9.090 | 4.37 / 3.30 |
| .5× scale | .499 / .782 | 1.902 / 2.403 | 3.81 / 3.07 |
| 2× scale | 1.711 / 2.686 | 7.307 / 9.173 | 4.27 / 3.42 |
| Oblique | 8.473 / 8.680 | 6.705 / 7.762 | .79 / .89 |
| Shear 2 | 4.877 / 5.243 | 5.719 / 6.511 | 1.17 / 1.24 |

The correctness replacement therefore has a material performance cost for some common filtered transforms. General sampling dominates those cases; flush, plane borrowing and completion account for only a small part. Exact integer-grid batching has removed the earlier integer-transform regression, and eight-pixel vector sampling improves the oblique path, but filtered scale/translation performance remains unfinished. No invisible fallback to the inaccurate native path is used to hide this cost. These measurements apply to the stated workload and machine; the tool retains the full matrix for independent reproduction.
