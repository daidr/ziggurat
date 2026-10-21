---
name: ziggurat-maintenance
description: Maintain Zig desktop applications built on the Ziggurat framework, including view changes, crash fixes, catalogs and toolchain or framework upgrades. Apply Ziggurat's ownership, lifetime, threading and testing rules.
---

# Ziggurat app maintenance

Check the framework checkout the app depends on (the `ziggurat` path or hash in `build.zig.zon`) and the app's own conventions before changing APIs. Read the framework's `docs/architecture.md`, `docs/philosophy.md` and the document of each module the change touches; confirm every API against that checkout, not memory. The app targets Zig 0.15.2 unless its build says otherwise.

## Ownership and lifetime

- Allocators are explicit: pass the app's allocator where an API asks for one. There is no global allocator, hidden worker pool, blocking UI wait or nested event loop; do not add one.
- `Window` is a value handle (App, slot, generation). The App outlives every handle use. A closed window's handle stays closed; never keep raw native pointers past `on_closed`.
- Content (a `ui.Context`, a `view.Host`, a WebView) stays at a stable address from attach until its detach callback. Window callback contexts stay valid through `on_closed`. `isClosed` includes closure in progress and is not permission to free.
- `requestClose`/`requestQuit` honor cancellation; `destroy`/`quit` force shutdown. Do not destroy or detach from inside a callback; let the framework defer it.

## Threads

- All native, UI and WebView operations and callbacks run on the main thread. Background work runs on threads the app owns and returns through `App.post`, whose `Full` or `Closed` result means the post did not take ownership.
- A successful post runs exactly once before shutdown completes; release what it carries there.

## Declarative views

- The build function describes the tree from state and may run several times per event: once per paint and once per delivered input. Put side effects in the branch where a control returns true, never unconditionally in the build.
- Node identity comes from the parent, sibling position and kind. Give `Style.key` to nodes whose sibling order changes (list items, conditional controls before others); keys are unique per parent.
- Bind controls to the app's persistent fields; a value recomputed in the build loses its edit.
- Keep the idle path event-driven: animate with `View.wakeAt` and a `ziggurat_view_timer.Timer`, and stop asking once nothing moves. Do not add a redraw timer or allocate in the draw path.
- Embedded leaves (`EmbedInput`) receive keys only while they hold focus; keep their context alive while the leaf is built.

## Catalogs

- Messages live in the catalogs named in `ziggurat.json` (`i18n.dir`, `i18n.source`). After editing them run `ziggurat i18n check`, then `ziggurat generate` to refresh `catalog.zig` and the page module. Never edit generated files by hand.

## Verification

- Reproduce view bugs with `view.Harness`: render, query, click, key, advance the clock, and render again while nodes disappear and return. Use `attachInput` for focus and keyboard paths.
- Run `zig fmt`, the app's `zig build test`, and its hidden-window smoke checks where it has them. Harness tests do not establish native input, accessibility or visual quality; say what remains unverified on each platform.
- For framework upgrades, read the framework's changes to the modules the app uses, rebuild, rerun the tests, and review stored handles, contexts and callback lifetimes by hand.
