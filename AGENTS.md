# Ziggurat contributor rules

Read `docs/architecture.md` and `docs/philosophy.md` before changing public APIs.

- Keep project documentation, code, comments, examples and generated files self-contained. Do not introduce names, code, attribution or comparisons from external reference frameworks.
- Target Zig 0.17.0 until a deliberate toolchain upgrade is tested. Code reaches `std.Io` through the shared `ziggurat_io` module (`src/io`), which owns the process-wide `Io`.
- Core owns lifecycle and window policy. Platform adapters translate native operations. UI and WebView remain separate dependency modules.
- Require explicit allocation and stable ownership. No global application allocator, hidden worker pool, blocking UI waits or nested event loops.
- `Window` is a value handle with an App, slot and generation. App must outlive every handle use. Reclaim closed native records after callback pins are released; reuse slots without reviving stale handles. Keep active and pending work independent of historical window count.
- All native/UI operations and callbacks run on the process main thread. `App.post` is the explicit cross-thread boundary.
- Every successful post executes once before shutdown completes. Return `Full` or `Closed` without taking ownership when a post fails.
- `requestClose` and `requestQuit` honor cancellation; `destroy` and `quit` force shutdown. Preflight all quit vetoes before automatic closure. Defer callback-triggered native destruction and detach to a safe point.
- Content detaches once. Context and View stay at stable addresses through detach; window callback contexts stay valid through `on_closed`, with shared contexts using the longer lifetime. `isClosed` includes closure in progress and is not permission to free context. Notify `on_closed` once after native destruction and detach, never for failed construction. Pending native callbacks retain their own state and never call detached Zig objects.
- Keep the idle path event-driven. Do not add a continuous redraw timer or allocate in the normal native draw path.
- Use `NO_STRICT` in Zig imports of Windows headers: opaque Win32 handles are tokens, not aligned struct pointers.
- Do not claim GPU acceleration, accessibility, cross-platform runtime support or performance results without corresponding implementation and verification.
- Run `zig fmt`, `zig build test`, `zig build check`, and the relevant hidden-window smoke check after lifecycle/input/backend changes: `smoke`, `smoke-lifecycle`, and `smoke-webview -Dwebview=true`. WebView checks require the pinned SDK and an installed Runtime.
- Unit tests use the test backend. Keep `tests/platform_check.zig` in `check` so cross-compilation also instantiates the ordinary target backend; compilation does not establish platform runtime support.
- Keep local validation caches on the project drive: Windows commands use `--global-cache-dir .zig-cache/managed/windows-global`; Linux probe scripts configure their local/global caches explicitly. Follow `docs/build-cache.md` for WSL's mounted Linux filesystem and the preview-first cleanup scripts. Stop all relevant builds before cleanup; preserve source checkpoints and validation logs.
- Browser screenshots and visual QA require a user request. Automated hidden-window integration checks do not establish visual quality.
