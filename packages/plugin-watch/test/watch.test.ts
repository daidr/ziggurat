import { afterEach, beforeEach, expect, test } from "bun:test";

type Listener = (event: { data: unknown }) => void;
type Frame = { session: string; kind: string; slot: number; id: number; method?: string; params?: Record<string, unknown>; sequence?: number };

const runtimeSession = "0123456789abcdef0123456789abcdef";
const watchSession = "fedcba9876543210fedcba9876543210";

const ready = { ready: true, events: [], more: false };
const part = (events: { op: string; path: string; oldPath?: string; isDir?: boolean }[], more = false) => ({
  ready: false,
  events: events.map((event) => ({ op: event.op, path: event.path, oldPath: event.oldPath ?? null, isDir: event.isDir ?? false })),
  more,
});

/** A host whose watch plugin answers with scripted parts. */
class FakeHost {
  listeners = new Set<Listener>();
  calls: Frame[] = [];
  cancels: Frame[] = [];
  /** What to answer a call with: parts go out as chunks, then the end unless held. */
  respond: (frame: Frame) => { parts: unknown[]; error?: { code: string; message: string }; hold?: boolean } = () => ({ parts: [ready], hold: true });
  held: Frame | undefined;

  transport = {
    postMessage: (message: string) => this.receive(message),
    addEventListener: (_type: "message", listener: Listener) => void this.listeners.add(listener),
    removeEventListener: (_type: "message", listener: Listener) => void this.listeners.delete(listener),
  };

  post(message: object) {
    const text = JSON.stringify(message);
    for (const listener of [...this.listeners]) listener({ data: text });
  }

  receive(message: string) {
    if (message === '{"ziggurat":"hello","v":1}') {
      queueMicrotask(() =>
        this.post({
          ziggurat: "runtime", v: 1, platform: "linux", windowId: 1, version: "0.1.0-dev", locale: "en", dir: "ltr",
          preferences: { accent: null, colorScheme: "light", reduceMotion: false, reduceTransparency: false, highContrast: false, textScale: 1 },
          services: { runtime: runtimeSession, "plugin:watch": watchSession },
        }),
      );
      return;
    }
    const frame = JSON.parse(message) as Frame;
    if (frame.session !== watchSession) return;
    if (frame.kind === "cancel") this.cancels.push(frame);
    if (frame.kind !== "call") return;
    this.calls.push(frame);
    const answer = this.respond(frame);
    queueMicrotask(() => {
      answer.parts.forEach((value, index) => this.chunk(frame, index + 1, value));
      if (answer.hold) {
        this.held = frame;
        return;
      }
      this.finish(frame, answer.error);
    });
  }

  chunk(frame: Frame, sequence: number, value: unknown) {
    this.post({ v: 1, session: watchSession, kind: "chunk", slot: frame.slot, id: frame.id, sequence, value });
  }

  finish(frame: Frame, error?: { code: string; message: string }) {
    if (error) this.post({ v: 1, session: watchSession, kind: "error", slot: frame.slot, id: frame.id, error });
    else this.post({ v: 1, session: watchSession, kind: "result", slot: frame.slot, id: frame.id, value: null });
  }
}

let host: FakeHost;
let plugin: typeof import("../src/index");

beforeEach(async () => {
  host = new FakeHost();
  (globalThis as Record<string, unknown>).chrome = { webview: host.transport };
  delete (globalThis as Record<symbol, unknown>)[Symbol.for("ziggurat.runtime")];
  plugin = await import(`../src/index.ts?${Math.random()}`);
});

afterEach(() => {
  delete (globalThis as Record<string, unknown>).chrome;
});

test("batches stream, parts of one batch arrive together, and close stops the host's watch", async () => {
  host.respond = () => ({
    parts: [
      ready,
      part([{ op: "create", path: "a" }], true),
      part([{ op: "rename", path: "lib", oldPath: "src", isDir: true }]),
      part([{ op: "remove", path: "a" }]),
    ],
    hold: true,
  });
  const w = await plugin.watch("project", { recursive: true });
  expect(host.calls[0]!.params).toEqual({ root: "project", path: ".", recursive: true, debounceMs: 0 });
  const iterator = w[Symbol.asyncIterator]();
  expect((await iterator.next()).value).toEqual([
    { op: "create", path: "a", isDir: false },
    { op: "rename", path: "lib", oldPath: "src", isDir: true },
  ]);
  expect((await iterator.next()).value).toEqual([{ op: "remove", path: "a", isDir: false }]);
  await w.close();
  await w.close();
  expect(host.cancels).toHaveLength(1);
  await expect(w.closed).resolves.toBeUndefined();
});

test("a watch that ends ends the iteration", async () => {
  host.respond = () => ({ parts: [ready, part([{ op: "remove", path: "." }])] });
  const w = await plugin.watch("project", { path: "config.json", debounceMs: -1 });
  expect(host.calls[0]!.params).toEqual({ root: "project", path: "config.json", recursive: false, debounceMs: -1 });
  const batches = [];
  for await (const batch of w) batches.push(batch);
  expect(batches).toEqual([[{ op: "remove", path: ".", isDir: false }]]);
  await expect(w.closed).resolves.toBeUndefined();
});

test("errors are WatchErrors with their code", async () => {
  host.respond = (frame) => {
    if ((frame.params as { root: string }).root === "denied") return { parts: [], error: { code: "denied", message: "filesystem watch denied" } };
    return { parts: [ready, part([{ op: "create", path: "a" }])], hold: true };
  };
  const denied = await plugin.watch("denied").catch((error: unknown) => error);
  expect(denied).toBeInstanceOf(plugin.WatchError);
  expect((denied as InstanceType<typeof plugin.WatchError>).code).toBe("denied");
  const w = await plugin.watch("project");
  const seen: unknown[] = [];
  const iterate = (async () => {
    for await (const batch of w) {
      seen.push(batch);
      // The host fails a watch once the page took the batches before.
      host.finish(host.held!, { code: "limit", message: "filesystem watch limit" });
    }
  })();
  await expect(iterate).rejects.toBeInstanceOf(plugin.WatchError);
  await expect(w.closed).rejects.toMatchObject({ code: "limit" });
  expect(seen).toHaveLength(1);
  await expect(w.close()).resolves.toBeUndefined();
});

test("an aborted signal stops the watch with its reason", async () => {
  const controller = new AbortController();
  const w = await plugin.watch("project", { signal: controller.signal });
  const iterate = (async () => {
    for await (const _ of w) {
    }
  })();
  controller.abort("stop");
  await expect(iterate).rejects.toBe("stop");
  await expect(w.closed).rejects.toBe("stop");
  expect(host.cancels).toHaveLength(1);
});

test("invalid options and an aborted signal never call the host", async () => {
  await expect(plugin.watch("project", { debounceMs: NaN })).rejects.toBeInstanceOf(TypeError);
  await expect(plugin.watch("project", { debounceMs: 60001 })).rejects.toBeInstanceOf(TypeError);
  await expect(plugin.watch("project", { signal: AbortSignal.abort("stop") })).rejects.toBe("stop");
  expect(host.calls).toHaveLength(0);
});
