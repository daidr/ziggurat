// Runs a Ziggurat application compiled to WebAssembly (wasm32-wasi) in a
// page. Load it with the module beside it:
//
//   <script src="ziggurat.js" data-app="app.wasm"></script>
//
// or start it yourself with `Ziggurat.run("app.wasm", options)`.
//
// A window is an element filling the page's element with the ID "ziggurat",
// or else the page; a window opened later covers the earlier ones. Each
// holds the canvas its frames show on and a textarea out of sight that has
// the keyboard while the window has: input methods compose in it at the
// content's caret, and its clipboard events carry the clipboard's text.
//
// The application's main thread is the page's: `App.run` gives it to the
// browser by unwinding the module's stack, and the page then calls into the
// module for each event, each frame it asked for and each posted task.
(function (global) {
  "use strict";

  const UNWIND = { ziggurat: "unwind" };
  class Exit extends Error {
    constructor(code) {
      super("exit " + code);
      this.code = code;
    }
  }

  const css = `
.ziggurat-window{position:absolute;inset:0;overflow:hidden;contain:strict}
body>.ziggurat-window{position:fixed}
.ziggurat-window>canvas{display:block;width:100%;height:100%;touch-action:none;outline:none;user-select:none;-webkit-user-select:none}
.ziggurat-menu{position:fixed;z-index:2147483647;min-width:160px;max-height:80vh;overflow:auto;margin:0;padding:4px 0;list-style:none;background:Canvas;color:CanvasText;border:1px solid color-mix(in srgb,CanvasText 20%,transparent);border-radius:6px;box-shadow:0 6px 24px rgba(0,0,0,.18);font:14px system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;user-select:none;-webkit-user-select:none}
.ziggurat-menu>li{position:relative;padding:5px 24px 5px 26px;white-space:nowrap;cursor:default}
.ziggurat-menu>li[aria-disabled=true]{opacity:.45}
.ziggurat-menu>li:not([aria-disabled=true]):hover,.ziggurat-menu>li.open{background:Highlight;color:HighlightText}
.ziggurat-menu>li[aria-checked=true]::before{content:"✓";position:absolute;left:9px}
.ziggurat-menu>li.submenu::after{content:"›";position:absolute;right:9px}
.ziggurat-menu>li.separator{height:1px;padding:0;margin:4px 0;background:color-mix(in srgb,CanvasText 15%,transparent)}
.ziggurat-window>textarea{position:absolute;left:0;top:0;width:1px;height:1em;padding:0;margin:0;border:0;outline:none;resize:none;overflow:hidden;opacity:0;color:transparent;background:transparent;caret-color:transparent;white-space:pre;font-size:16px;z-index:-1}
`;

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const utf16Decoder = new TextDecoder("utf-16le");
  // The fonts the renderers name, as CSS: the interface's system family,
  // with the emoji fonts after it, or the fixed-pitch one.
  const sansFamilies = 'system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", sans-serif, "Apple Color Emoji", "Segoe UI Emoji"';
  const monoFamilies = 'ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace';
  const cssFont = (size, weight, italic, mono) => `${italic ? "italic " : ""}${weight || 400} ${size.toFixed(2)}px ${mono ? monoFamilies : sansFamilies}`;
  const mac = /^Mac/.test((global.navigator && navigator.platform) || "");

  // Wire constants, as src/platform/web.zig reads them.
  const EVENT_SIZE = 80;
  const lineHeight = 16;

  function run(source, options) {
    options = options || {};
    const rt = new Runtime(options);
    return rt.start(source);
  }

  class Runtime {
    constructor(options) {
      this.options = options;
      this.args = options.args || ["app"];
      this.env = options.env || {};
      this.windows = new Map();
      this.nextWindow = 1;
      this.depth = 0;
      this.queue = [];
      this.wakePending = false;
      this.quitting = false;
      this.stdout = "";
      this.stderr = "";
      this.textCanvas = null;
      this.textCache = new Map();
      this.textLast = null;
      this.clipboardText = "";
      this.listeners = [];
      this.timers = new Map();
      this.fontCache = new Map();
      this.watches = new Map();
      this.nextWatch = 1;
      this.padKeys = new Map();
      this.nextPad = 1;
      this.audio = new Map();
      this.measureCache = new Map();
      this.segmenters = new Map();
    }

    async start(source) {
      const imports = { wasi_snapshot_preview1: this.wasi(), ziggurat: this.host(), env: this.desktop() };
      const response = typeof source === "string" ? fetch(source) : source;
      let result;
      if (WebAssembly.instantiateStreaming && typeof source === "string") {
        try {
          result = await WebAssembly.instantiateStreaming(response, imports);
        } catch (err) {
          // A server sending WebAssembly with another type.
          const bytes = await (await fetch(source)).arrayBuffer();
          result = await WebAssembly.instantiate(bytes, imports);
        }
      } else {
        const bytes = source instanceof ArrayBuffer ? source : await (await response).arrayBuffer();
        result = await WebAssembly.instantiate(bytes, imports);
      }
      this.instance = result.instance;
      this.exports = this.instance.exports;
      this.memory = this.exports.memory;
      this.eventAt = this.exports.ziggurat_event_buffer ? this.exports.ziggurat_event_buffer() : 0;
      global.ziggurat = this;
      try {
        this.depth++;
        this.exports._start();
        this.depth--;
        this.flush();
        return { exited: 0 };
      } catch (err) {
        this.depth--;
        if (err === UNWIND) {
          this.drain();
          return { running: true, runtime: this };
        }
        this.flush();
        if (err instanceof Exit) return { exited: err.code };
        throw err;
      }
    }

    // Memory views; memory can grow, which detaches older views.
    u8() {
      return new Uint8Array(this.memory.buffer);
    }
    dv() {
      return new DataView(this.memory.buffer);
    }
    string(ptr, len) {
      return decoder.decode(new Uint8Array(this.memory.buffer, ptr, len));
    }
    // Writes bytes to the module's scratch, returning [ptr, len].
    scratch(bytes) {
      const ptr = this.exports.ziggurat_scratch(bytes.length);
      if (!ptr) return [0, 0];
      this.u8().set(bytes, ptr);
      return [ptr, bytes.length];
    }

    flush() {
      if (this.stdout) console.log(this.stdout), (this.stdout = "");
      if (this.stderr) console.error(this.stderr), (this.stderr = "");
    }

    // The WASI functions the standard library calls. There are no files:
    // the browser's are the ones dropped on a window.
    wasi() {
      const rt = this;
      const ENOSYS = 52,
        EBADF = 8,
        ENOENT = 44,
        SUCCESS = 0;
      const writeStrings = (list, countPtr, sizePtr) => {
        const dv = rt.dv();
        dv.setUint32(countPtr, list.length, true);
        dv.setUint32(sizePtr, list.reduce((n, s) => n + encoder.encode(s).length + 1, 0), true);
        return SUCCESS;
      };
      const fillStrings = (list, ptrs, buf) => {
        const dv = rt.dv();
        const u8 = rt.u8();
        let at = buf;
        list.forEach((s, i) => {
          dv.setUint32(ptrs + i * 4, at, true);
          const b = encoder.encode(s);
          u8.set(b, at);
          u8[at + b.length] = 0;
          at += b.length + 1;
        });
        return SUCCESS;
      };
      const envList = () => Object.entries(rt.env).map(([k, v]) => k + "=" + v);
      const origin = performance.now();
      return {
        args_sizes_get: (c, s) => writeStrings(rt.args, c, s),
        args_get: (p, b) => fillStrings(rt.args, p, b),
        environ_sizes_get: (c, s) => writeStrings(envList(), c, s),
        environ_get: (p, b) => fillStrings(envList(), p, b),
        clock_res_get: (id, out) => {
          rt.dv().setBigUint64(out, 1000n, true);
          return SUCCESS;
        },
        clock_time_get: (id, precision, out) => {
          let ns;
          if (id === 0) ns = BigInt(Math.round(Date.now() * 1e6));
          else ns = BigInt(Math.round((performance.now() - origin) * 1e6)) + 1000000000n;
          rt.dv().setBigUint64(out, ns, true);
          return SUCCESS;
        },
        fd_write: (fd, iovs, count, written) => {
          const dv = rt.dv();
          let total = 0;
          let text = "";
          for (let i = 0; i < count; i++) {
            const ptr = dv.getUint32(iovs + i * 8, true);
            const len = dv.getUint32(iovs + i * 8 + 4, true);
            text += decoder.decode(new Uint8Array(rt.memory.buffer, ptr, len));
            total += len;
          }
          if (fd === 1 || fd === 2) {
            const key = fd === 1 ? "stdout" : "stderr";
            rt[key] += text;
            const lines = rt[key].split("\n");
            rt[key] = lines.pop();
            for (const line of lines) (fd === 1 ? console.log : console.error)(line);
          } else return EBADF;
          dv.setUint32(written, total, true);
          return SUCCESS;
        },
        fd_fdstat_get: (fd, out) => {
          if (fd > 2) return EBADF;
          const dv = rt.dv();
          dv.setUint8(out, 2); // character device
          dv.setUint16(out + 2, 0, true);
          dv.setBigUint64(out + 8, 0xffffffffn, true);
          dv.setBigUint64(out + 16, 0xffffffffn, true);
          return SUCCESS;
        },
        fd_prestat_get: () => EBADF,
        fd_prestat_dir_name: () => EBADF,
        fd_close: () => SUCCESS,
        fd_read: () => EBADF,
        fd_pread: () => EBADF,
        fd_pwrite: () => EBADF,
        fd_seek: () => EBADF,
        fd_sync: () => EBADF,
        fd_readdir: () => EBADF,
        fd_filestat_get: () => EBADF,
        fd_filestat_set_size: () => EBADF,
        fd_filestat_set_times: () => EBADF,
        path_open: () => ENOENT,
        path_filestat_get: () => ENOENT,
        path_filestat_set_times: () => ENOENT,
        path_create_directory: () => ENOSYS,
        path_link: () => ENOSYS,
        path_readlink: () => ENOENT,
        path_remove_directory: () => ENOSYS,
        path_rename: () => ENOSYS,
        path_symlink: () => ENOSYS,
        path_unlink_file: () => ENOSYS,
        poll_oneoff: () => ENOSYS,
        sched_yield: () => SUCCESS,
        random_get: (ptr, len) => {
          const u8 = rt.u8();
          for (let at = 0; at < len; at += 65536) crypto.getRandomValues(u8.subarray(ptr + at, ptr + Math.min(len, at + 65536)));
          return SUCCESS;
        },
        proc_exit: (code) => {
          rt.flush();
          throw new Exit(code);
        },
      };
    }

    // Calls into the module, unless a call is under way: an event the
    // browser sends while the module runs (a focus that focusing caused)
    // waits for that call to return.
    call(fn) {
      if (this.depth > 0) {
        this.queue.push(fn);
        return 0;
      }
      this.depth++;
      try {
        return fn();
      } catch (err) {
        if (err === UNWIND) return 0;
        throw err;
      } finally {
        this.depth--;
        if (this.depth === 0) this.drain();
      }
    }
    drain() {
      while (this.queue.length && this.depth === 0) {
        const next = this.queue.shift();
        this.call(next);
      }
    }
    // Sends an event to a window's record: fields of the wire struct.
    send(win, ev) {
      if (this.quitting || !win || win.destroyed) return 0;
      return this.call(() => {
        if (win.destroyed && ev.kind !== 11) return 0;
        const dv = this.dv();
        const at = this.eventAt;
        new Uint8Array(this.memory.buffer, at, EVENT_SIZE).fill(0);
        dv.setInt32(at + 0, ev.kind | 0, true);
        dv.setInt32(at + 4, ev.key | 0, true);
        dv.setInt32(at + 8, ev.flags | 0, true);
        dv.setUint32(at + 12, ev.width >>> 0 || 0, true);
        dv.setUint32(at + 16, ev.height >>> 0 || 0, true);
        dv.setFloat64(at + 24, ev.x || 0, true);
        dv.setFloat64(at + 32, ev.y || 0, true);
        dv.setFloat64(at + 40, ev.dx || 0, true);
        dv.setFloat64(at + 48, ev.dy || 0, true);
        dv.setFloat64(at + 56, ev.scale || 1, true);
        if (ev.text !== undefined) {
          const bytes = typeof ev.text === "string" ? encoder.encode(ev.text) : ev.text;
          const [ptr, len] = this.scratch(bytes);
          const view = this.dv();
          view.setUint32(at + 64, ptr, true);
          view.setUint32(at + 68, len, true);
        }
        this.dv().setUint32(at + 72, ev.selection >>> 0 || 0, true);
        return this.exports.ziggurat_window_event(win.record);
      });
    }

    host() {
      const rt = this;
      return {
        zw_app_init: () => (global.document ? 0 : 2),
        zw_app_run: () => {
          rt.listenPage();
          throw UNWIND;
        },
        zw_app_wake: () => rt.wake(),
        zw_app_quit: () => {
          rt.quitting = true;
        },
        zw_window_create: (record, titlePtr, titleLen, flags) => rt.createWindow(record, rt.string(titlePtr, titleLen), flags),
        zw_window_destroy: (id) => rt.destroyWindow(id),
        zw_window_action: (id, action) => rt.windowAction(id, action),
        zw_window_state: (id) => rt.windowState(id),
        zw_window_size: (id, out) => {
          const win = rt.windows.get(id);
          const dv = rt.dv();
          const [w, h, s] = win ? rt.pixels(win) : [0, 0, 1];
          dv.setFloat64(out, w, true);
          dv.setFloat64(out + 8, h, true);
          dv.setFloat64(out + 16, s, true);
        },
        zw_window_bounds: (id, out) => {
          const win = rt.windows.get(id);
          const r = win ? win.el.getBoundingClientRect() : { x: 0, y: 0, width: 0, height: 0 };
          const dv = rt.dv();
          dv.setFloat64(out, r.x, true);
          dv.setFloat64(out + 8, r.y, true);
          dv.setFloat64(out + 16, r.width, true);
          dv.setFloat64(out + 24, r.height, true);
        },
        zw_window_title: (id, ptr, len) => {
          const win = rt.windows.get(id);
          if (!win) return;
          win.title = rt.string(ptr, len);
          if (win.title) document.title = win.title;
        },
        zw_window_invalidate: (id) => rt.requestFrame(rt.windows.get(id)),
        zw_window_caret: (id, x, y, w, h) => {
          const win = rt.windows.get(id);
          if (!win) return;
          const st = win.input.style;
          st.left = x + "px";
          st.top = y + "px";
          st.height = Math.max(h, 1) + "px";
          if (!win.textActive) {
            win.textActive = true;
            win.input.setAttribute("inputmode", "text");
          }
        },
        zw_window_cancel_composition: (id) => {
          const win = rt.windows.get(id);
          if (!win) return;
          win.composing = false;
          win.input.value = "";
          if (document.activeElement === win.input) {
            // Blurring ends the input method's composition.
            rt.queue.push(() => 0);
            win.ignoreFocus = true;
            win.input.blur();
            win.input.focus({ preventScroll: true });
            win.ignoreFocus = false;
          }
        },
        zw_window_text_mode: (id, keyboard) => {
          const win = rt.windows.get(id);
          if (win) win.keyboardMode = keyboard !== 0;
        },
        zw_window_cursor: (id, ptr, len) => {
          const win = rt.windows.get(id);
          if (win) win.canvas.style.cursor = rt.string(ptr, len);
        },
        zw_window_fullscreen: (id, on) => {
          const win = rt.windows.get(id);
          if (!win) return;
          win.fullscreenRequested = on !== 0;
          if (on && win.el.requestFullscreen) win.el.requestFullscreen().catch(() => {});
          if (!on && document.fullscreenElement) document.exitFullscreen().catch(() => {});
        },
        zw_window_background: (id, rgba) => {
          const win = rt.windows.get(id);
          if (!win) return;
          win.el.style.background = rgba ? "#" + (rgba >>> 8).toString(16).padStart(6, "0") : "";
        },
        zw_window_capture: (id, out) => {
          const win = rt.windows.get(id);
          if (!win || !win.canvas.width || !win.canvas.height) return 0;
          const ctx = win.ctx;
          const data = ctx.getImageData(0, 0, win.canvas.width, win.canvas.height).data;
          const ptr = rt.exports.ziggurat_alloc(data.length);
          if (!ptr) return 0;
          rt.u8().set(data, ptr);
          const dv = rt.dv();
          dv.setUint32(out, win.canvas.width, true);
          dv.setUint32(out + 4, win.canvas.height, true);
          dv.setUint32(out + 8, win.canvas.width * 4, true);
          return ptr;
        },
        zw_present: (id, pixels, width, height, stride, transparent) => rt.present(id, pixels, width, height, stride, transparent),
        zw_text_draw: (textPtr, textLen, fontPtr, fontLen, size, maxWidth, offset, rgb, out) =>
          rt.drawText(rt.string(textPtr, textLen), rt.string(fontPtr, fontLen), size, maxWidth, offset, rgb, out),
        zw_measure_text: (textPtr, len, size, weight, italic, mono) => rt.measureText(rt.string(textPtr, len), cssFont(size, weight, italic, mono)),
        zw_layout_font: (fontPtr, fontLen, out) => {
          const [ascent, descent] = rt.fontMetrics(rt.string(fontPtr, fontLen));
          const dv = rt.dv();
          dv.setFloat64(out, ascent, true);
          dv.setFloat64(out + 8, descent, true);
        },
        zw_layout_segments: (textPtr, len, localePtr, localeLen, kind, out, capacity) =>
          rt.segments(rt.utf16(textPtr, len), rt.string(localePtr, localeLen), kind, out, capacity),
        zw_layout_advances: (textPtr, len, fontPtr, fontLen, out) => rt.advances(rt.utf16(textPtr, len), rt.string(fontPtr, fontLen), out),
        zw_layout_begin: (width, height, scale, left, top, fontPtr, fontLen, rtl) =>
          rt.maskBegin(width, height, scale, left, top, rt.string(fontPtr, fontLen), rtl),
        zw_layout_draw: (textPtr, len, x, baseline) => rt.maskCtx.fillText(rt.utf16(textPtr, len), x, baseline),
        zw_layout_end: (mask, stride) => rt.maskEnd(mask, stride),
        zw_audio_open: (engine, rate, aheadMs, audible) => rt.audioOpen(engine, rate, aheadMs, audible),
        zw_audio_close: (engine) => rt.audioClose(engine),
        zw_gamepads: (keys, capacity) => {
          const pads = rt.gamepads();
          const n = Math.min(pads.length, capacity);
          new Uint32Array(rt.memory.buffer, keys, n).set(pads.slice(0, n).map((p) => p.key));
          return n;
        },
        zw_gamepad_name: (key, buffer, capacity) => {
          const pad = rt.gamepads().find((p) => p.key === key);
          if (!pad) return 0;
          const bytes = encoder.encode(pad.pad.id).subarray(0, capacity);
          rt.u8().set(bytes, buffer);
          return bytes.length;
        },
        zw_gamepad_read: (key, buttons, axes) => {
          const pad = rt.gamepads().find((p) => p.key === key);
          if (!pad) return 0;
          const b = new Float32Array(rt.memory.buffer, buttons, 17),
            a = new Float32Array(rt.memory.buffer, axes, 4);
          for (let i = 0; i < 17; i++) {
            const button = pad.pad.buttons[i];
            b[i] = button ? (typeof button.value === "number" && button.value > 0 ? button.value : button.pressed ? 1 : 0) : 0;
          }
          for (let i = 0; i < 4; i++) a[i] = pad.pad.axes[i] || 0;
          return 1;
        },
        zw_clipboard_write: (ptr, len) => {
          rt.clipboardText = rt.string(ptr, len);
          rt.clipboardHeld = true;
          // Outside a copy event the page asks the browser, which may refuse.
          if (!rt.inCopy && navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(rt.clipboardText).catch(() => {});
        },
        zw_clipboard_read: (ptr, capacity) => {
          if (!rt.clipboardHeld) return -1;
          const bytes = encoder.encode(rt.clipboardText);
          if (bytes.length <= capacity) rt.u8().set(bytes, ptr);
          return bytes.length;
        },
        zw_menu_popup: (owner, serial, win, items, len, kind, x, y) => rt.popupMenu(owner, serial, win, rt.string(items, len), kind, x, y),
        zw_menu_cancel: (owner) => rt.closeMenu(owner, -1),
        zw_message: (ptr, len, buttons) => {
          const text = rt.string(ptr, len);
          if (buttons <= 1) {
            alert(text);
            return 0;
          }
          return confirm(text) ? 0 : -1;
        },
        zw_open_url: (ptr, len) => {
          global.open(rt.string(ptr, len), "_blank", "noopener");
        },
        zw_history_fragment: (buffer, capacity) => {
          const hash = global.location ? location.hash : "";
          if (!hash.startsWith("#/")) return 0;
          const bytes = encoder.encode(decodeURIComponent(hash.slice(1)));
          if (bytes.length > capacity) return 0;
          rt.u8().set(bytes, buffer);
          return bytes.length;
        },
        zw_history_state: () => {
          const state = history.state;
          return state && typeof state.zigguratEntry === "number" ? state.zigguratEntry : -1;
        },
        zw_history_write: (push, number, ptr, len) => {
          rt.listenHistory();
          if (global.top !== global.self) return;
          const loc = rt.string(ptr, len);
          history[push ? "pushState" : "replaceState"]({ zigguratEntry: number }, "", "#" + loc);
        },
        zw_history_go: (n) => {
          if (global.top === global.self) history.go(n);
        },
        zw_timer_arm: (timer, ms) => {
          clearTimeout(rt.timers.get(timer));
          rt.timers.set(
            timer,
            setTimeout(() => {
              rt.timers.delete(timer);
              if (!rt.quitting) rt.call(() => rt.exports.ziggurat_timer_fired(timer));
            }, Math.max(0, ms))
          );
        },
        zw_timer_cancel: (timer) => {
          clearTimeout(rt.timers.get(timer));
          rt.timers.delete(timer);
        },
        zw_text_copy: (ptr) => {
          const last = rt.textLast;
          if (last) new Uint32Array(rt.memory.buffer, ptr, last.width * last.height).set(last.pixels);
        },
      };
    }

    wake() {
      if (this.wakePending) return;
      this.wakePending = true;
      const run = () => {
        this.wakePending = false;
        if (!this.quitting) this.call(() => this.exports.ziggurat_dispatch());
      };
      if (typeof MessageChannel !== "undefined") {
        if (!this.channel) {
          this.channel = new MessageChannel();
          this.channel.port1.onmessage = () => this.wakeRun();
        }
        this.wakeRun = run;
        this.channel.port2.postMessage(0);
      } else setTimeout(run, 0);
    }

    // Connected pads in the standard mapping, each with a key that stays
    // while it is connected.
    gamepads() {
      const list = typeof navigator !== "undefined" && navigator.getGamepads ? Array.from(navigator.getGamepads()) : [];
      const seen = [];
      for (const pad of list) {
        if (!pad || !pad.connected || pad.mapping !== "standard") continue;
        let known = this.padKeys.get(pad.index);
        if (!known || known.id !== pad.id) {
          known = { id: pad.id, key: this.nextPad++ };
          this.padKeys.set(pad.index, known);
        }
        seen.push({ key: known.key, pad });
      }
      for (const index of Array.from(this.padKeys.keys())) if (!list[index] || !list[index].connected) this.padKeys.delete(index);
      return seen;
    }

    // Context menus: menus of HTML on the page, at a point of the window or
    // where the pointer was last. Arrows, Enter and Escape work in them.
    popupMenu(owner, serial, id, text, kind, x, y) {
      this.closeMenu(null, -1);
      const win = this.windows.get(id);
      const items = text
        .split("\x1e")
        .filter((t) => t.length)
        .map((t, index) => {
          const [k, enabled, checked, parent, label] = t.split("\x1f");
          return { index, kind: k, enabled: enabled === "1", checked: checked === "1", parent: +parent - 1, label };
        });
      let px = this.pointer ? this.pointer[0] : 0,
        py = this.pointer ? this.pointer[1] : 0;
      if (kind === 1 && win) {
        const r = win.el.getBoundingClientRect();
        px = r.left + x;
        py = r.top + y;
      } else if (kind === 2) {
        px = x - (global.screenX || 0);
        py = y - (global.screenY || 0);
      }
      const menu = { owner, serial, lists: [], win };
      this.menu = menu;
      const finish = (index) => this.closeMenu(owner, index);
      const build = (parent, left, top) => {
        const ul = document.createElement("ul");
        ul.className = "ziggurat-menu";
        ul.setAttribute("role", "menu");
        ul.tabIndex = -1;
        for (const item of items) {
          if (item.parent !== parent) continue;
          const li = document.createElement("li");
          if (item.kind === "-") {
            li.className = "separator";
            li.setAttribute("role", "separator");
          } else {
            li.textContent = item.label;
            li.setAttribute("role", "menuitem");
            if (!item.enabled) li.setAttribute("aria-disabled", "true");
            if (item.checked) li.setAttribute("aria-checked", "true");
            if (item.kind === "s") {
              li.className = "submenu";
              li.addEventListener("pointerenter", () => openSub(li, item, ul));
              li.addEventListener("click", () => openSub(li, item, ul));
            } else {
              li.addEventListener("pointerenter", () => closeAfter(ul));
              li.addEventListener("click", () => item.enabled && finish(item.index));
            }
          }
          ul.appendChild(li);
        }
        document.body.appendChild(ul);
        const w = ul.offsetWidth,
          h = ul.offsetHeight;
        ul.style.left = Math.max(0, Math.min(left, innerWidth - w)) + "px";
        ul.style.top = Math.max(0, Math.min(top, innerHeight - h)) + "px";
        menu.lists.push(ul);
        return ul;
      };
      const closeAfter = (ul) => {
        const at = menu.lists.indexOf(ul);
        for (const extra of menu.lists.splice(at + 1)) extra.remove();
        for (const li of ul.children) li.classList.remove("open");
      };
      const openSub = (li, item, ul) => {
        if (!item.enabled || li.classList.contains("open")) return;
        closeAfter(ul);
        li.classList.add("open");
        const r = li.getBoundingClientRect();
        build(item.index, r.right - 2, r.top - 5);
      };
      build(-1, px, py);
      menu.outside = (e) => {
        if (!menu.lists.some((ul) => ul.contains(e.target))) finish(-1);
      };
      menu.keys = (e) => {
        if (e.key === "Escape") {
          e.preventDefault();
          finish(-1);
        }
      };
      setTimeout(() => {
        if (this.menu !== menu) return;
        document.addEventListener("pointerdown", menu.outside, true);
        document.addEventListener("keydown", menu.keys, true);
        global.addEventListener("blur", menu.outside);
      }, 0);
    }
    closeMenu(owner, index) {
      const menu = this.menu;
      if (!menu || (owner !== null && menu.owner !== owner)) return;
      this.menu = null;
      for (const ul of menu.lists) ul.remove();
      document.removeEventListener("pointerdown", menu.outside, true);
      document.removeEventListener("keydown", menu.keys, true);
      global.removeEventListener("blur", menu.outside);
      if (menu.win && menu.win.input) menu.win.input.focus({ preventScroll: true });
      this.call(() => this.exports.ziggurat_owner_popup(menu.owner, menu.serial, index));
    }

    // The desktop's preferences, screen, power and network, as the page
    // knows them: the zsd_* entry points of src/system/desktop.zig. A page
    // chooses the appearance with data-ziggurat-theme="dark" or "light" on
    // its root element.
    desktop() {
      const rt = this;
      const query = (q) => (global.matchMedia ? global.matchMedia(q) : null);
      const scheme = () => {
        const forced = document.documentElement.getAttribute("data-ziggurat-theme");
        if (forced === "dark") return 2;
        if (forced === "light") return 1;
        const q = query("(prefers-color-scheme: dark)");
        return q ? (q.matches ? 2 : 1) : 0;
      };
      const flag = (q) => {
        const m = query(q);
        return !m || m.media === "not all" ? -1 : m.matches ? 1 : 0;
      };
      return {
        zsd_preferences: (out) => {
          const dv = rt.dv();
          dv.setInt32(out, scheme(), true);
          dv.setUint32(out + 4, flag("(prefers-contrast: more)") === 1 || flag("(forced-colors: active)") === 1 ? 1 : 0, true);
          dv.setUint32(out + 8, flag("(prefers-reduced-motion: reduce)") === 1 ? 1 : 0, true);
          dv.setFloat32(out + 12, 1, true);
          dv.setInt32(out + 16, -1, true);
          dv.setInt32(out + 20, flag("(prefers-reduced-transparency: reduce)"), true);
          return 0;
        },
        zsd_monitors: (out, capacity, count) => {
          const dv = rt.dv();
          if (capacity < 1) return 3;
          const s = global.screen || { width: innerWidth, height: innerHeight, availWidth: innerWidth, availHeight: innerHeight };
          const v = [0, 0, s.width, s.height, s.availLeft || 0, s.availTop || 0, s.availWidth, s.availHeight];
          v.forEach((x, i) => (i % 4 < 2 ? dv.setInt32(out + i * 4, x, true) : dv.setUint32(out + i * 4, x, true)));
          dv.setFloat32(out + 32, global.devicePixelRatio || 1, true);
          dv.setUint32(out + 36, 1, true);
          dv.setUint32(out + 40, 0, true);
          dv.setUint32(count, 1, true);
          return 0;
        },
        zsd_power: (out) => {
          const dv = rt.dv();
          const b = rt.battery;
          dv.setInt32(out, b ? (b.charging ? 1 : 2) : 0, true);
          dv.setInt32(out + 4, b ? Math.round(b.level * 100) : -1, true);
          dv.setInt32(out + 8, -1, true);
          return 0;
        },
        zsd_network: (out) => {
          const dv = rt.dv();
          const online = typeof navigator !== "undefined" && "onLine" in navigator ? (navigator.onLine ? 1 : 2) : 0;
          const c = typeof navigator !== "undefined" && navigator.connection;
          dv.setInt32(out, online, true);
          dv.setInt32(out + 4, c && typeof c.saveData === "boolean" ? (c.saveData ? 1 : 0) : -1, true);
          return 0;
        },
        zsd_watch_start: (bits, owner, callback, handle) => {
          const id = rt.nextWatch++;
          const fire = (changed) => {
            if (!rt.watches.has(id) || !(changed & bits)) return;
            rt.call(() => rt.exports.__indirect_function_table.get(callback)(owner, changed & bits));
          };
          const undo = [];
          const on = (target, type, fn) => {
            if (!target) return;
            target.addEventListener(type, fn);
            undo.push(() => target.removeEventListener(type, fn));
          };
          for (const q of ["(prefers-color-scheme: dark)", "(prefers-contrast: more)", "(forced-colors: active)", "(prefers-reduced-motion: reduce)", "(prefers-reduced-transparency: reduce)"]) on(query(q), "change", () => fire(2));
          if (typeof MutationObserver !== "undefined") {
            const observer = new MutationObserver(() => fire(2));
            observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-ziggurat-theme"] });
            undo.push(() => observer.disconnect());
          }
          on(global, "resize", () => fire(1));
          on(global, "online", () => fire(8));
          on(global, "offline", () => fire(8));
          if (navigator.getBattery && bits & 4)
            navigator.getBattery().then((b) => {
              rt.battery = b;
              if (!rt.watches.has(id)) return;
              on(b, "chargingchange", () => fire(4));
              on(b, "levelchange", () => fire(4));
            });
          rt.watches.set(id, undo);
          rt.dv().setUint32(handle, id, true);
          return 0;
        },
        zsd_watch_stop: (id) => {
          const undo = rt.watches.get(id);
          rt.watches.delete(id);
          if (undo) for (const fn of undo) fn();
        },
        zsd_resource_count: () => rt.watches.size,
        zsd_beep: () => 1,
        zsd_cursor: (x, y) => {
          if (!rt.pointer) return 1;
          const dv = rt.dv();
          dv.setInt32(x, Math.round(rt.pointer[0] + (global.screenX || 0)), true);
          dv.setInt32(y, Math.round(rt.pointer[1] + (global.screenY || 0)), true);
          return 0;
        },
      };
    }

    // The tab's history: the browser's back and forward buttons, and a
    // location typed into the address bar, reach the router following it.
    listenHistory() {
      if (this.historyListening) return;
      this.historyListening = true;
      global.addEventListener("popstate", () => {
        const state = history.state;
        const number = state && typeof state.zigguratEntry === "number" ? state.zigguratEntry : -1;
        const hash = location.hash.startsWith("#/") ? decodeURIComponent(location.hash.slice(1)) : "";
        const [ptr, len] = this.scratch(encoder.encode(hash));
        this.call(() => this.exports.ziggurat_history_popped(number, ptr, len));
        for (const win of this.windows.values()) this.requestFrame(win, true);
      });
    }

    // Audio: a Web Audio output per engine that asks the module for
    // frames on the main thread. Pages may only start sound after a press
    // or a key, so a suspended context resumes on the next one.
    audioOpen(engine, rate, aheadMs, audible) {
      const AC = global.AudioContext || global.webkitAudioContext;
      if (!AC) return;
      let ctx;
      try {
        ctx = new AC({ sampleRate: rate, latencyHint: aheadMs > 100 ? "playback" : "interactive" });
      } catch (err) {
        return;
      }
      const frames = aheadMs > 100 ? 8192 : 2048;
      const node = ctx.createScriptProcessor(frames, 0, 2);
      const gain = ctx.createGain();
      gain.gain.value = audible ? 1 : 0;
      node.onaudioprocess = (e) => {
        const left = e.outputBuffer.getChannelData(0),
          right = e.outputBuffer.getChannelData(1);
        let ptr = 0;
        if (!this.quitting) this.call(() => (ptr = this.exports.ziggurat_audio_pull(engine, left.length)));
        if (!ptr) {
          left.fill(0);
          right.fill(0);
          return;
        }
        const samples = new Float32Array(this.memory.buffer, ptr, left.length * 2);
        for (let i = 0; i < left.length; i++) {
          left[i] = samples[2 * i];
          right[i] = samples[2 * i + 1];
        }
      };
      node.connect(gain);
      gain.connect(ctx.destination);
      this.audio.set(engine, { ctx, node, gain });
      if (ctx.state !== "running") {
        const resume = () => {
          for (const a of this.audio.values()) if (a.ctx.state !== "running") a.ctx.resume();
        };
        for (const type of ["pointerdown", "keydown", "touchend"]) document.addEventListener(type, resume, { capture: true, once: true });
      }
    }
    audioClose(engine) {
      const a = this.audio.get(engine);
      if (!a) return;
      this.audio.delete(engine);
      a.node.onaudioprocess = null;
      a.node.disconnect();
      a.gain.disconnect();
      a.ctx.close();
    }

    // Page-wide listeners: the device pixel ratio and the page's size.
    listenPage() {
      if (this.pageListening) return;
      this.pageListening = true;
      const measureAll = () => {
        for (const win of this.windows.values()) if (this.measure(win)) this.requestFrame(win);
      };
      window.addEventListener("resize", measureAll);
      document.addEventListener("visibilitychange", () => {
        if (!document.hidden) for (const win of this.windows.values()) this.requestFrame(win, true);
      });
      document.addEventListener("fullscreenchange", () => {
        for (const win of this.windows.values()) {
          win.fullscreen = document.fullscreenElement === win.el;
          if (!win.fullscreen) win.fullscreenRequested = false;
          this.send(win, { kind: 16 });
        }
      });
    }

    createWindow(record, title, flags) {
      if (!this.styled) {
        this.styled = true;
        const style = document.createElement("style");
        style.textContent = css;
        document.head.appendChild(style);
      }
      let parent = document.getElementById("ziggurat");
      if (!parent) parent = document.body;
      else if (getComputedStyle(parent).position === "static") parent.style.position = "relative";
      const id = this.nextWindow++;
      const el = document.createElement("div");
      el.className = "ziggurat-window";
      el.style.display = "none";
      const canvas = document.createElement("canvas");
      canvas.tabIndex = -1;
      const input = document.createElement("textarea");
      for (const [k, v] of Object.entries({ autocomplete: "off", autocorrect: "off", autocapitalize: "off", spellcheck: "false", tabindex: "-1", inputmode: "none" }))
        input.setAttribute(k, v);
      el.appendChild(canvas);
      el.appendChild(input);
      parent.appendChild(el);
      const win = {
        id,
        record,
        el,
        canvas,
        input,
        ctx: canvas.getContext("2d", { alpha: (flags & 1) !== 0 }),
        title,
        transparent: (flags & 1) !== 0,
        focusOnShow: (flags & 4) !== 0,
        visible: false,
        focused: false,
        enabled: true,
        fullscreen: false,
        fullscreenRequested: (flags & 2) !== 0,
        width: 0,
        height: 0,
        scale: 1,
        pending: false,
        image: null,
        destroyed: false,
        composing: false,
        copied: false,
      };
      this.windows.set(id, win);
      if (title) document.title = title;
      this.listen(win);
      return id;
    }

    destroyWindow(id) {
      const win = this.windows.get(id);
      if (!win) return;
      win.destroyed = true;
      if (win.frame) cancelAnimationFrame(win.frame);
      if (win.observer) win.observer.disconnect();
      win.el.remove();
      this.windows.delete(id);
      // The page's title is the title of the window opened last.
      let last = null;
      for (const other of this.windows.values()) last = other;
      if (last && last.title) document.title = last.title;
    }

    windowAction(id, action) {
      const win = this.windows.get(id);
      if (!win) return;
      switch (action) {
        case 0: // show
        case 4: // restore
          if (!win.visible) {
            win.visible = true;
            win.el.style.display = "";
            this.measure(win);
            this.requestFrame(win, true);
            this.send(win, { kind: 16 });
          }
          // A window shown in a frame of another page leaves that page the
          // keyboard until it is clicked.
          if (action === 0 && win.focusOnShow && global.top === global.self) this.queue.push(() => (win.input.focus({ preventScroll: true }), 0));
          break;
        case 1: // hide
          if (win.visible) {
            win.visible = false;
            win.el.style.display = "none";
            this.send(win, { kind: 16 });
          }
          break;
        case 5: // focus
          this.queue.push(() => (win.input.focus({ preventScroll: true }), 0));
          break;
        case 6:
          win.enabled = true;
          this.send(win, { kind: 16 });
          break;
        case 7:
          win.enabled = false;
          this.send(win, { kind: 16 });
          break;
      }
    }

    windowState(id) {
      const win = this.windows.get(id);
      if (!win) return 0;
      return (win.visible ? 1 : 0) | (win.focused ? 8 : 0) | (win.enabled ? 16 : 0) | (win.fullscreen ? 32 : 0) | (win.fullscreenRequested ? 64 : 0);
    }

    // The canvas's size in device pixels and the device pixel ratio.
    pixels(win) {
      return [Math.ceil(Math.fround(win.width) * Math.fround(win.scale)), Math.ceil(Math.fround(win.height) * Math.fround(win.scale)), win.scale];
    }
    measure(win) {
      if (!win.visible) return false;
      const r = win.canvas.getBoundingClientRect();
      const scale = global.devicePixelRatio > 0 ? global.devicePixelRatio : 1;
      if (r.width === win.width && r.height === win.height && scale === win.scale) return false;
      win.width = r.width;
      win.height = r.height;
      win.scale = scale;
      const [w, h] = this.pixels(win);
      this.send(win, { kind: 2, width: w, height: h, scale });
      return true;
    }
    requestFrame(win, force) {
      if (!win || win.destroyed) return;
      if (force) win.dirty = true;
      win.dirty = true;
      if (win.pending) return;
      win.pending = true;
      win.frame = requestAnimationFrame(() => this.drawFrame(win));
    }
    drawFrame(win) {
      win.pending = false;
      if (win.destroyed || !win.visible || !win.dirty) return;
      win.dirty = false;
      this.measure(win);
      const [w, h, scale] = this.pixels(win);
      if (!w || !h) return;
      if (win.canvas.width !== w || win.canvas.height !== h) {
        win.canvas.width = w;
        win.canvas.height = h;
      }
      this.send(win, { kind: 1, width: w, height: h, scale, flags: win.transparent ? 1 : 0 });
    }
    // Shows a frame drawn in memory: premultiplied BGRA to the straight
    // RGBA of ImageData.
    present(id, pixels, width, height, stride, transparent) {
      const win = this.windows.get(id);
      if (!win || !width || !height) return;
      if (!win.image || win.image.width !== width || win.image.height !== height) win.image = win.ctx.createImageData(width, height);
      const out = new Uint32Array(win.image.data.buffer);
      const src = new Uint32Array(this.memory.buffer, pixels, (stride / 4) * height);
      const row = stride / 4;
      for (let y = 0; y < height; y++) {
        let s = y * row;
        let d = y * width;
        for (let x = 0; x < width; x++, s++, d++) {
          const p = src[s];
          const a = p >>> 24;
          let r = (p >>> 16) & 255,
            g = (p >>> 8) & 255,
            b = p & 255;
          if (a !== 255 && a !== 0) {
            r = Math.min(255, ((r * 255 + (a >> 1)) / a) | 0);
            g = Math.min(255, ((g * 255 + (a >> 1)) / a) | 0);
            b = Math.min(255, ((b * 255 + (a >> 1)) / a) | 0);
          }
          out[d] = (a << 24) | (b << 16) | (g << 8) | r;
        }
      }
      win.ctx.putImageData(win.image, 0, 0);
      if (this.options.onFrame) this.options.onFrame(win);
    }

    // Draws a run of text on the text canvas, for the renderer, which
    // copies its pixels with zw_text_copy: the browser finds the fonts,
    // falls back for what one lacks and shapes, as for its pages.
    drawText(text, font, size, maxWidth, offset, rgb, out) {
      offset = Math.round(offset * 4) / 4;
      const key = font + "\u0000" + text + "\u0000" + maxWidth.toFixed(2) + "\u0000" + offset + "\u0000" + rgb;
      let entry = this.textCache.get(key);
      if (entry) {
        this.textCache.delete(key);
        this.textCache.set(key, entry);
      } else {
        entry = this.renderText(text, font, size, maxWidth, offset, rgb);
        this.textCache.set(key, entry);
        if (this.textCache.size > 1024) this.textCache.delete(this.textCache.keys().next().value);
      }
      this.textLast = entry;
      const dv = this.dv();
      const info = [entry.width, entry.height, entry.left, entry.top, entry.ascent, entry.descent];
      info.forEach((v, i) => dv.setFloat64(out + i * 8, v, true));
      return 0;
    }
    textContext() {
      if (!this.textCanvas) {
        this.textCanvas = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(64, 64) : document.createElement("canvas");
        this.textCtx = this.textCanvas.getContext("2d", { willReadFrequently: true });
      }
      return this.textCtx;
    }
    renderText(text, font, size, maxWidth, offset, rgb) {
      const ctx = this.textContext();
      ctx.font = font;
      let shown = text;
      let m = ctx.measureText(shown);
      if (m.width > maxWidth + 0.01) {
        // Cut at a grapheme with an ellipsis, as the desktops cut a line.
        const parts = typeof Intl !== "undefined" && Intl.Segmenter ? Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text), (s) => s.segment) : Array.from(text);
        let lo = 0,
          hi = parts.length;
        while (lo < hi) {
          const mid = (lo + hi + 1) >> 1;
          if (ctx.measureText(parts.slice(0, mid).join("") + "…").width <= maxWidth) lo = mid;
          else hi = mid - 1;
        }
        shown = parts.slice(0, lo).join("").replace(/\s+$/, "") + "…";
        if (ctx.measureText(shown).width > maxWidth + 0.01 && lo === 0) shown = "";
        m = ctx.measureText(shown);
      }
      const ascent = typeof m.fontBoundingBoxAscent === "number" ? m.fontBoundingBoxAscent : size * 0.9;
      const descent = typeof m.fontBoundingBoxDescent === "number" ? m.fontBoundingBoxDescent : size * 0.25;
      const pad = Math.ceil(size * 0.5) + 2;
      const asc = Math.ceil(Math.max(ascent, m.actualBoundingBoxAscent || 0));
      const desc = Math.ceil(Math.max(descent, m.actualBoundingBoxDescent || 0));
      const width = shown ? Math.ceil(m.width + offset) + 2 * pad : 0;
      const height = shown ? asc + desc + 2 * pad : 0;
      const entry = { width, height, left: -pad, top: -(pad + asc), ascent, descent, pixels: new Uint32Array(width * height) };
      if (!width || !height) return entry;
      const canvas = this.textCanvas;
      if (canvas.width < width || canvas.height < height) {
        canvas.width = Math.max(canvas.width, width);
        canvas.height = Math.max(canvas.height, height);
      }
      ctx.font = font;
      ctx.clearRect(0, 0, width, height);
      ctx.textBaseline = "alphabetic";
      ctx.textAlign = "left";
      ctx.direction = "ltr";
      ctx.fillStyle = "#" + rgb.toString(16).padStart(6, "0");
      ctx.fillText(shown, pad + offset, pad + asc);
      const data = ctx.getImageData(0, 0, width, height).data;
      const px = entry.pixels;
      for (let i = 0, j = 0; i < px.length; i++, j += 4) {
        const a = data[j + 3];
        if (!a) continue;
        const r = ((data[j] * a + 127) / 255) | 0,
          g = ((data[j + 1] * a + 127) / 255) | 0,
          b = ((data[j + 2] * a + 127) / 255) | 0;
        px[i] = ((a << 24) | (r << 16) | (g << 8) | b) >>> 0;
      }
      return entry;
    }

    measureText(text, font) {
      const key = font + "\u0000" + text;
      let width = this.measureCache.get(key);
      if (width === undefined) {
        const ctx = this.textContext();
        ctx.font = font;
        width = ctx.measureText(text).width;
        if (this.measureCache.size > 4096) this.measureCache.clear();
        this.measureCache.set(key, width);
      }
      return width;
    }
    utf16(ptr, len) {
      return utf16Decoder.decode(new Uint16Array(this.memory.buffer, ptr, len));
    }
    fontMetrics(font) {
      let m = this.fontCache.get(font);
      if (!m) {
        const ctx = this.textContext();
        ctx.font = font;
        const t = ctx.measureText("Hg");
        const size = parseFloat(/([\d.]+)px/.exec(font)?.[1] || "16");
        m = [
          typeof t.fontBoundingBoxAscent === "number" ? t.fontBoundingBoxAscent : size * 0.9,
          typeof t.fontBoundingBoxDescent === "number" ? t.fontBoundingBoxDescent : size * 0.25,
        ];
        this.fontCache.set(font, m);
      }
      return m;
    }
    segmenter(locale, granularity) {
      const key = locale + "\u0000" + granularity;
      let s = this.segmenters.get(key);
      if (!s && typeof Intl !== "undefined" && Intl.Segmenter) {
        try {
          s = new Intl.Segmenter(locale || undefined, { granularity });
        } catch (err) {
          s = new Intl.Segmenter(undefined, { granularity });
        }
        this.segmenters.set(key, s);
      }
      return s;
    }
    // Graphemes (kind 0), words (1) and line break opportunities (2) of a
    // text, in UTF-16 offsets, from the page's Unicode segmentation.
    segments(text, locale, kind, out, capacity) {
      const values = [];
      if (kind === 0) {
        const seg = this.segmenter(locale, "grapheme");
        if (seg) for (const s of seg.segment(text)) values.push(s.index);
        else for (let i = 0; i < text.length; i++) if (!(text.charCodeAt(i) >= 0xdc00 && text.charCodeAt(i) < 0xe000)) values.push(i);
      } else if (kind === 1) {
        const ends = [],
          lexical = [];
        const seg = this.segmenter(locale, "word");
        if (seg)
          for (const s of seg.segment(text)) {
            ends.push(s.index + s.segment.length);
            lexical.push(s.isWordLike ? 1 : 0);
          }
        else if (text.length) ends.push(text.length), lexical.push(0);
        values.push(...ends, ...lexical);
      } else {
        // A break may follow spaces and dashes, and come on either side of
        // an ideograph, kana or Hangul syllable, never before closing marks.
        const wide = (c) => (c >= 0x2e80 && c <= 0x9fff) || (c >= 0xac00 && c <= 0xd7af) || (c >= 0xf900 && c <= 0xfaff) || (c >= 0xff00 && c <= 0xffef) || (c >= 0x20000 && c <= 0x3134f);
        const closing = ",.;:!?)]}\u3001\u3002\uff0c\uff0e\uff1a\uff1b\uff01\uff1f\uff09\u300d\u300f\u3011\u30fc\u3005\u309d\u30fd";
        const space = (c) => c === 0x20 || c === 0x09 || c === 0x3000 || c === 0x200b;
        let prev = -1;
        for (let i = 0; i < text.length; ) {
          const c = text.codePointAt(i);
          const n = c > 0xffff ? 2 : 1;
          if (i > 0 && prev >= 0) {
            const after = space(prev) && !space(c);
            const dash = (prev === 0x2d || prev === 0x2010 || prev === 0x2013 || prev === 0x2014 || prev === 0x2f) && !space(c);
            const ideo = (wide(prev) || wide(c)) && !space(c) && !closing.includes(String.fromCodePoint(c)) && !"([{\u300c\u300e\u3010\uff08".includes(String.fromCodePoint(prev));
            if (after || dash || ideo) values.push(i);
          }
          prev = c;
          i += n;
        }
      }
      if (values.length > capacity) return -1;
      new Uint32Array(this.memory.buffer, out, values.length).set(values);
      return kind === 1 ? values.length / 2 : values.length;
    }
    // The pen's x at each UTF-16 offset of a text, restarting at each hard
    // line. Pieces between spaces are measured whole, so their kerning and
    // shaping count; graphemes inside a piece end where its prefix ends.
    advances(text, font, out) {
      const ctx = this.textContext();
      ctx.font = font;
      const pen = new Float32Array(this.memory.buffer, out, text.length + 1);
      const seg = this.segmenter("", "grapheme");
      const starts = seg ? Array.from(seg.segment(text), (s) => s.index) : Array.from({ length: text.length }, (_, i) => i);
      starts.push(text.length);
      const hard = (c) => c === 10 || c === 13 || c === 11 || c === 12 || c === 0x85 || c === 0x2028 || c === 0x2029;
      let base = 0,
        piece = 0,
        x = 0;
      const tab = ctx.measureText("    ").width;
      for (let g = 0; g < starts.length - 1; g++) {
        const at = starts[g],
          end = starts[g + 1],
          c = text.charCodeAt(at);
        for (let i = at; i < end; i++) pen[i] = x;
        if (hard(c)) {
          base = 0;
          x = 0;
          piece = end;
          for (let i = at + 1; i <= end; i++) if (i < text.length) pen[i] = 0;
          continue;
        }
        if (c === 9) {
          base = x + tab;
          x = base;
          piece = end;
        } else if (c === 32 || end - piece > 64) {
          // Each space ends a piece, which bounds the prefixes measured.
          x = base + ctx.measureText(text.slice(piece, end)).width;
          base = x;
          piece = end;
        } else x = base + ctx.measureText(text.slice(piece, end)).width;
      }
      pen[text.length] = x;
    }
    // Prepared text: lines of a layout drawn white on a canvas, whose
    // alpha becomes the coverage mask.
    maskBegin(width, height, scale, left, top, font, rtl) {
      if (!this.maskCanvas) {
        this.maskCanvas = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(width, height) : document.createElement("canvas");
        this.maskCtx = this.maskCanvas.getContext("2d", { willReadFrequently: true });
      }
      const canvas = this.maskCanvas;
      if (canvas.width < width || canvas.height < height) {
        canvas.width = Math.max(canvas.width, width);
        canvas.height = Math.max(canvas.height, height);
      }
      const ctx = this.maskCtx;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, width, height);
      ctx.setTransform(scale, 0, 0, scale, -left, -top);
      ctx.font = font;
      ctx.textBaseline = "alphabetic";
      ctx.textAlign = "left";
      ctx.direction = "ltr";
      ctx.fillStyle = "#fff";
      this.maskSize = [width, height];
      return 0;
    }
    maskEnd(mask, stride) {
      const [width, height] = this.maskSize;
      const data = this.maskCtx.getImageData(0, 0, width, height).data;
      const u8 = this.u8();
      for (let y = 0; y < height; y++) {
        const row = mask + y * stride;
        for (let x = 0, j = y * width * 4 + 3; x < width; x++, j += 4) u8[row + x] = data[j];
      }
    }

    // The modifiers of an event: Command is Control on a Mac, as the
    // content's shortcuts take a browser for a system other than macOS.
    mods(e) {
      let ctrl = e.ctrlKey,
        meta = e.metaKey;
      if (mac) [ctrl, meta] = [meta, ctrl];
      return (e.shiftKey ? 1 : 0) | (ctrl ? 2 : 0) | (e.altKey ? 4 : 0) | (meta ? 8 : 0);
    }
    point(win, e) {
      const r = win.canvas.getBoundingClientRect();
      return [e.clientX - r.left, e.clientY - r.top];
    }
    allowed(win) {
      return this.depth === 0 ? this.send(win, { kind: 17 }) !== 0 : true;
    }

    listen(win) {
      const c = win.canvas,
        input = win.input;
      if (typeof ResizeObserver !== "undefined") {
        win.observer = new ResizeObserver(() => {
          if (this.measure(win)) this.requestFrame(win, true);
        });
        win.observer.observe(c);
      }
      c.addEventListener("pointermove", (e) => {
        this.pointer = [e.clientX, e.clientY];
        const [x, y] = this.point(win, e);
        this.send(win, { kind: 5, x, y, flags: this.mods(e) });
      });
      c.addEventListener("pointerdown", (e) => {
        e.preventDefault();
        this.pointer = [e.clientX, e.clientY];
        if (document.activeElement !== input) input.focus({ preventScroll: true });
        const [x, y] = this.point(win, e);
        const button = { 0: 0, 1: 2, 2: 1, 3: 3, 4: 4 }[e.button];
        if (button === undefined) return;
        try {
          c.setPointerCapture(e.pointerId);
        } catch (_) {}
        if (!this.allowed(win)) return;
        this.send(win, { kind: 3, key: button, x, y, flags: this.mods(e) });
      });
      const up = (e) => {
        const [x, y] = this.point(win, e);
        const button = { 0: 0, 1: 2, 2: 1, 3: 3, 4: 4 }[e.button];
        if (button === undefined) return;
        this.send(win, { kind: 4, key: button, x, y, flags: this.mods(e) });
      };
      c.addEventListener("pointerup", up);
      c.addEventListener("pointercancel", (e) => {
        up(e);
        this.send(win, { kind: 8 });
      });
      // iOS sends a tap's mouse events after its pointer events: the
      // mousedown would take the keyboard from the textarea.
      c.addEventListener("mousedown", (e) => e.preventDefault());
      c.addEventListener("contextmenu", (e) => e.preventDefault());
      c.addEventListener(
        "wheel",
        (e) => {
          e.preventDefault();
          const [x, y] = this.point(win, e);
          let dx = e.deltaX,
            dy = e.deltaY;
          if (e.deltaMode === 1) (dx *= lineHeight), (dy *= lineHeight);
          else if (e.deltaMode === 2) (dx *= win.width), (dy *= win.height);
          this.send(win, { kind: 6, x, y, dx, dy, flags: this.mods(e) });
        },
        { passive: false }
      );
      input.addEventListener("focus", () => {
        if (win.ignoreFocus) return;
        win.focused = true;
        this.send(win, { kind: 7, flags: 1 });
        this.send(win, { kind: 16 });
      });
      input.addEventListener("blur", () => {
        if (win.ignoreFocus) return;
        win.focused = false;
        this.send(win, { kind: 7, flags: 0 });
        this.send(win, { kind: 16 });
      });
      input.addEventListener("keydown", (e) => this.key(win, e, true));
      input.addEventListener("keyup", (e) => this.key(win, e, false));
      input.addEventListener("beforeinput", (e) => {
        switch (e.inputType) {
          case "insertText":
            if (!e.isComposing && !win.composing) {
              e.preventDefault();
              if (e.data) this.send(win, { kind: 12, text: e.data });
            }
            break;
          case "insertCompositionText":
          case "deleteCompositionText":
          case "insertFromComposition":
            break;
          default:
            // Keys did what the rest do (Enter, Backspace, ...); a paste
            // comes as its own event.
            e.preventDefault();
        }
      });
      input.addEventListener("compositionstart", () => {
        win.composing = true;
      });
      input.addEventListener("compositionupdate", (e) => {
        const text = e.data || "";
        this.send(win, { kind: 13, text, selection: encoder.encode(text).length });
      });
      input.addEventListener("compositionend", (e) => {
        win.composing = false;
        this.send(win, { kind: 14 });
        if (e.data) this.send(win, { kind: 12, text: e.data });
        input.value = "";
      });
      const copy = (e, edit) => {
        e.preventDefault();
        this.inCopy = true;
        try {
          if (!win.copied) this.send(win, { kind: 9, key: edit, flags: 2 });
          // An offer renders its text now, while the event lasts.
          if (this.exports.ziggurat_clipboard_flush) this.call(() => this.exports.ziggurat_clipboard_flush());
        } finally {
          this.inCopy = false;
        }
        win.copied = false;
        if (e.clipboardData && this.clipboardHeld) e.clipboardData.setData("text/plain", this.clipboardText);
      };
      input.addEventListener("copy", (e) => copy(e, 9));
      input.addEventListener("cut", (e) => copy(e, 10));
      input.addEventListener("paste", (e) => {
        e.preventDefault();
        const data = e.clipboardData;
        if (!data) return;
        this.clipboardText = data.getData("text/plain");
        this.clipboardHeld = true;
        this.send(win, { kind: 9, key: 11, flags: 2 });
      });
    }

    // A key going down or up in the textarea. Keys typing text come as
    // text from beforeinput after this; keys an input method takes are its.
    key(win, e, down) {
      if (down) win.copied = false;
      if (e.isComposing || e.keyCode === 229) return;
      const name = e.key;
      if (name === "Dead" || name === "Process" || name === "Unidentified" || name === "Compose") return;
      const mods = this.mods(e);
      const text = name + "\u0000" + e.code;
      if (!down) {
        this.send(win, { kind: 26, text, flags: mods });
        return;
      }
      if (!this.allowed(win)) {
        e.preventDefault();
        return;
      }
      const primary = (mods & 2) !== 0;
      const plain = !(mods & (4 | 1));
      const lower = name.length === 1 ? name.toLowerCase() : "";
      // The paste event brings the clipboard's text; copying and cutting
      // happen now, and their events give the browser the text.
      if (primary && plain && lower === "v") return;
      if (this.send(win, { kind: 18, text, flags: mods | (e.repeat ? 16 : 0) })) {
        e.preventDefault();
        if (primary && plain && (lower === "c" || lower === "x")) win.copied = true;
        return;
      }
      if (primary && !(mods & 4)) {
        const edit = { a: 8, c: 9, x: 10, z: 12, y: 13 }[lower];
        if (edit !== undefined) {
          this.send(win, { kind: 9, key: edit, flags: 2 | (mods & 1) });
          if (lower === "c" || lower === "x") win.copied = true;
          else e.preventDefault();
          return;
        }
      }
      if (!(mods & (2 | 4))) {
        if (name === "Tab") {
          e.preventDefault();
          this.send(win, { kind: 15, key: 0, flags: mods });
          return;
        }
        if (name === "Enter" || (name === " " && !win.textActive)) {
          e.preventDefault();
          this.send(win, { kind: 15, key: 1, flags: mods });
          return;
        }
      }
      const edits = { ArrowLeft: 0, ArrowRight: 1, ArrowUp: 2, ArrowDown: 3, Home: 4, End: 5, Backspace: 6, Delete: 7 };
      if (name in edits && !(mods & 4)) {
        e.preventDefault();
        this.send(win, { kind: 9, key: edits[name], flags: (mods & 1) | (mods & 2) });
        return;
      }
      if (name === "F5" || name === "F11" || name === "F12") return;
      if ([...name].length > 1 || primary) e.preventDefault();
    }
  }

  global.Ziggurat = { run, Runtime };

  // <script src="ziggurat.js" data-app="app.wasm"> starts the app once the
  // page has its body.
  const script = global.document && document.currentScript;
  const app = script && script.dataset && script.dataset.app;
  if (app) {
    const start = () =>
      run(app).catch((err) => {
        console.error(err);
      });
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
    else start();
  }
})(typeof window !== "undefined" ? window : globalThis);
