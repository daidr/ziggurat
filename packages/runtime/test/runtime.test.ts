import { afterEach, beforeEach, expect, test } from "bun:test";

type Listener = (event: { data: unknown }) => void;

/** A host that answers like the Zig page runtime, for one document. */
class FakeHost {
  listeners = new Set<Listener>();
  sent: string[] = [];
  received: Record<string, unknown>[] = [];
  subscriptions = new Map<string, number>();
  maximized = false;
  title = "";
  sessions = { runtime: "0123456789abcdef0123456789abcdef", "plugin:echo": "fedcba9876543210fedcba9876543210" };
  configure = true;

  transport = {
    postMessage: (message: string) => this.receive(message),
    addEventListener: (_type: "message", listener: Listener) => void this.listeners.add(listener),
    removeEventListener: (_type: "message", listener: Listener) => void this.listeners.delete(listener),
  };

  post(message: string) {
    this.sent.push(message);
    for (const listener of [...this.listeners]) listener({ data: message });
  }

  receive(message: string) {
    if (message === '{"ziggurat":"hello","v":1}') {
      if (!this.configure) return;
      queueMicrotask(() =>
        this.post(
          JSON.stringify({
            ziggurat: "runtime",
            v: 1,
            platform: "linux",
            windowId: 7,
            version: "0.1.0-dev",
            locale: "en",
            dir: "ltr",
            preferences: { accent: "#0a84ff", colorScheme: "dark", reduceMotion: false, reduceTransparency: false, highContrast: false, textScale: 1 },
            services: this.sessions,
          }),
        ),
      );
      return;
    }
    const frame = JSON.parse(message);
    this.received.push(frame);
    const reply = (value: unknown) =>
      queueMicrotask(() => this.post(JSON.stringify({ v: 1, session: frame.session, kind: "result", slot: frame.slot, id: frame.id, value })));
    if (frame.session !== this.sessions.runtime) {
      // The echo plugin answers its calls with their params.
      if (frame.kind === "call") reply(frame.params.text);
      return;
    }
    switch (frame.kind) {
      case "subscribe":
        this.subscriptions.set(frame.event, frame.subscription);
        return;
      case "unsubscribe":
        this.subscriptions.delete(frame.event);
        return;
      case "call":
        switch (frame.method) {
          case "toggleMaximize":
            this.maximized = !this.maximized;
            return reply(null);
          case "isMaximized":
            return reply(this.maximized);
          case "setTitle":
            this.title = frame.params.title;
            return reply(null);
          case "closeWindow":
            return queueMicrotask(() =>
              this.post(JSON.stringify({ v: 1, session: frame.session, kind: "error", slot: frame.slot, id: frame.id, error: { code: "unavailable", message: "Closed" } })),
            );
          default:
            return reply(null);
        }
    }
  }

  emit(event: string, value: unknown) {
    const subscription = this.subscriptions.get(event);
    if (!subscription) return false;
    this.post(JSON.stringify({ v: 1, session: this.sessions.runtime, kind: "event", event, subscription, value }));
    return true;
  }
}

let host: FakeHost;
let runtime: typeof import("../src/index");
const style = new Map<string, string>();

beforeEach(async () => {
  host = new FakeHost();
  style.clear();
  (globalThis as Record<string, unknown>).chrome = { webview: host.transport };
  (globalThis as Record<string, unknown>).document = {
    documentElement: { style: { setProperty: (n: string, v: string) => style.set(n, v), removeProperty: (n: string) => style.delete(n) } },
  };
  delete (globalThis as Record<symbol, unknown>)[Symbol.for("ziggurat.runtime")];
  runtime = await import(`../src/index.ts?${Math.random()}`);
});

afterEach(() => {
  delete (globalThis as Record<string, unknown>).chrome;
  delete (globalThis as Record<string, unknown>).document;
});

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("connect performs one handshake per document", async () => {
  expect(runtime.isZiggurat()).toBe(true);
  expect(() => runtime.runtime()).toThrow("connect()");
  const [a, b] = await Promise.all([runtime.connect(), runtime.connect()]);
  expect(a).toBe(b);
  expect(a.platform).toBe("linux");
  expect(a.windowId).toBe(7);
  expect(a.services).toEqual(["runtime", "plugin:echo"]);
  expect(runtime.locale()).toBe("en");
  expect(runtime.direction()).toBe("ltr");
  expect(runtime.preferences().colorScheme).toBe("dark");
  expect(style.get("--ziggurat-accent")).toBe("#0a84ff");
  expect(style.get("--ziggurat-text-scale")).toBe("1");
  // The runtime keeps the locale and preferences current itself.
  expect([...host.subscriptions.keys()].sort()).toEqual(["locale", "preferences"]);
});

test("outside a window everything rejects", async () => {
  delete (globalThis as Record<string, unknown>).chrome;
  expect(runtime.isZiggurat()).toBe(false);
  await expect(runtime.connect()).rejects.toThrow("not in a Ziggurat window");
  await expect(runtime.currentWindow.minimize()).rejects.toThrow();
});

test("window controls call the runtime service", async () => {
  await runtime.currentWindow.toggleMaximize();
  expect(await runtime.currentWindow.isMaximized()).toBe(true);
  await runtime.currentWindow.setTitle("Notes");
  expect(host.title).toBe("Notes");
  const error = await runtime.currentWindow.close().catch((e: unknown) => e);
  expect(runtime.isRemoteError(error)).toBe(true);
  expect((error as { code: string }).code).toBe("unavailable");
  expect(host.received.filter((f) => f.kind === "call").map((f) => f.method)).toEqual(["toggleMaximize", "isMaximized", "setTitle", "closeWindow"]);
});

test("locale and preference changes update the runtime before page listeners run", async () => {
  await runtime.connect();
  const seen: string[] = [];
  const off = runtime.onLocaleChange((locale, dir) => seen.push(`${locale}/${dir}/${runtime.locale()}`));
  const prefs: string[] = [];
  runtime.onPreferences((p) => prefs.push(`${p.accent}/${runtime.preferences().highContrast}`));
  await tick();
  host.emit("locale", { locale: "ar", dir: "rtl" });
  host.emit("preferences", { accent: null, colorScheme: "light", reduceMotion: true, reduceTransparency: true, highContrast: true, textScale: 1.5 });
  expect(seen).toEqual(["ar/rtl/ar"]);
  expect(prefs).toEqual(["null/true"]);
  expect(runtime.direction()).toBe("rtl");
  expect(style.has("--ziggurat-accent")).toBe(false);
  expect(style.get("--ziggurat-text-scale")).toBe("1.5");
  off();
  host.emit("locale", { locale: "en", dir: "ltr" });
  expect(seen.length).toBe(1);
});

test("listeners added before the connection subscribe once it exists", async () => {
  const drops: string[][] = [];
  const off = runtime.onFileDrop(({ paths }) => drops.push([...paths]));
  const cancelled = runtime.onDocumentReload(() => drops.push(["reload"]));
  cancelled();
  await runtime.connect();
  await tick();
  expect(host.subscriptions.has("fileDrop")).toBe(true);
  expect(host.subscriptions.has("documentReload")).toBe(false);
  host.emit("fileDrop", { paths: ["/tmp/a", "/tmp/b"], x: 1, y: 2 });
  expect(drops).toEqual([["/tmp/a", "/tmp/b"]]);
  off();
  expect(host.subscriptions.has("fileDrop")).toBe(false);
});

test("plugin services get their own client on their own session", async () => {
  // A minimal generated-client shape: post a call, resolve on the result.
  const create = (post: (m: string) => void, session: string) => {
    const pending = new Map<number, (value: unknown) => void>();
    let id = 0;
    return {
      session,
      receive(message: string) {
        const frame = JSON.parse(message);
        pending.get(frame.id)?.(frame.value);
      },
      close() {},
      echo(text: string) {
        const call = ++id;
        post(JSON.stringify({ v: 1, session, kind: "call", slot: 0, id: call, method: "echo", params: { text } }));
        return new Promise((resolve) => pending.set(call, resolve));
      },
    };
  };
  const client = await runtime.service("plugin:echo", create);
  expect(client.session).toBe(host.sessions["plugin:echo"]);
  expect(await runtime.service("plugin:echo", create)).toBe(client);
  expect(await client.echo("hi")).toBe("hi");
  await expect(runtime.service("plugin:missing", create)).rejects.toThrow("Host.use");
  // Messages of other sessions and the app's own messages are left alone.
  host.post("app message");
  host.post('{"v":1,"session":"00000000000000000000000000000000","kind":"result","slot":0,"id":1,"value":1}');
});
