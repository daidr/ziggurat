import { afterEach, beforeEach, expect, test } from "bun:test";

type Listener = (event: { data: unknown }) => void;
type Frame = { session: string; kind: string; slot: number; id: number; method?: string; params?: Record<string, unknown>; sequence?: number };

const runtimeSession = "0123456789abcdef0123456789abcdef";
const pluginSession = "fedcba9876543210fedcba9876543210";

const event = (kind: string, extra: Record<string, unknown> = {}) => ({ kind, protocol: null, data: null, last: false, code: 0, reason: null, clean: false, error: null, ...extra });

/** A host whose WebSocket plugin the test drives by hand. */
class FakeHost {
  listeners = new Set<Listener>();
  connects: Frame[] = [];
  sends: Frame[] = [];
  cancels: Frame[] = [];
  plugin = true;
  sequences = new Map<number, number>();
  /** Answers send calls at once unless held. */
  holdSends = false;
  held: Frame[] = [];

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
      const services: Record<string, string> = { runtime: runtimeSession };
      if (this.plugin) services["plugin:websocket"] = pluginSession;
      queueMicrotask(() =>
        this.post({
          ziggurat: "runtime", v: 1, platform: "linux", windowId: 1, version: "0.1.0-dev", locale: "en", dir: "ltr",
          preferences: { accent: null, colorScheme: "light", reduceMotion: false, reduceTransparency: false, highContrast: false, textScale: 1 },
          services,
        }),
      );
      return;
    }
    const frame = JSON.parse(message) as Frame;
    if (frame.session !== pluginSession) return;
    if (frame.kind === "cancel") this.cancels.push(frame);
    if (frame.kind !== "call") return;
    if (frame.method === "connect") this.connects.push(frame);
    else {
      this.sends.push(frame);
      if (this.holdSends) this.held.push(frame);
      else queueMicrotask(() => this.result(frame));
    }
  }

  emit(connect: Frame, value: object) {
    const sequence = (this.sequences.get(connect.id) ?? 0) + 1;
    this.sequences.set(connect.id, sequence);
    this.post({ v: 1, session: pluginSession, kind: "chunk", slot: connect.slot, id: connect.id, sequence, value });
  }

  result(frame: Frame) {
    this.post({ v: 1, session: pluginSession, kind: "result", slot: frame.slot, id: frame.id, value: null });
  }

  error(frame: Frame, code: string, message: string) {
    this.post({ v: 1, session: pluginSession, kind: "error", slot: frame.slot, id: frame.id, error: { code, message } });
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

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

async function opened(url = "wss://example.com/live", protocols: string[] = [], headers?: HeadersInit) {
  const ws = new plugin.WebSocket(url, protocols, { headers });
  while (host.connects.length === 0) await tick();
  return { ws, connect: host.connects.at(-1)! };
}

test("a connection opens, receives messages in pieces and closes cleanly", async () => {
  const { ws, connect } = await opened("https://example.com/live?room=1", ["v1", "v2"], { Authorization: "Bearer token" });
  expect(ws.url).toBe("wss://example.com/live?room=1");
  expect(ws.readyState).toBe(plugin.WebSocket.CONNECTING);
  expect(connect.params!.protocols).toEqual(["v1", "v2"]);
  expect(connect.params!.headers).toEqual([{ name: "authorization", value: "Bearer token" }]);
  const seen: string[] = [];
  ws.onopen = () => seen.push(`open ${ws.protocol}`);
  ws.binaryType = "arraybuffer";
  ws.addEventListener("message", (e) => seen.push(typeof e.data === "string" ? `text ${e.data}` : `binary ${new Uint8Array(e.data as ArrayBuffer).join(",")}`));
  ws.onclose = (e) => seen.push(`close ${e.code} ${e.reason} ${e.wasClean}`);
  host.emit(connect, event("open", { protocol: "v2" }));
  host.emit(connect, event("text", { data: btoa("hé".slice(0, 1)), last: false }));
  host.emit(connect, event("text", { data: btoa(String.fromCharCode(...new TextEncoder().encode("é"))), last: true }));
  host.emit(connect, event("binary", { data: btoa("\x01\x02"), last: true }));
  host.emit(connect, event("close", { code: 4000, reason: "bye", clean: true }));
  host.result(connect);
  await tick();
  await tick();
  expect(seen).toEqual(["open v2", "text hé", "binary 1,2", "close 4000 bye true"]);
  expect(ws.readyState).toBe(plugin.WebSocket.CLOSED);
});

test("messages go in order, in pieces, and bufferedAmount counts what the host has not taken", async () => {
  const { ws, connect } = await opened();
  host.emit(connect, event("open"));
  await tick();
  expect(() => new plugin.WebSocket("wss://example.com/").send("x")).toThrow("not open");
  host.holdSends = true;
  ws.send("hello");
  ws.send(new Uint8Array(70 * 1024).fill(7));
  ws.close(4001, "done");
  expect(ws.bufferedAmount).toBe(5 + 70 * 1024);
  expect(ws.readyState).toBe(plugin.WebSocket.CLOSING);
  // Sends after close are counted and dropped.
  ws.send("late");
  expect(ws.bufferedAmount).toBe(5 + 70 * 1024 + 4);
  const answered: Record<string, unknown>[] = [];
  while (answered.length < 5) {
    await tick();
    const frame = host.held.shift();
    if (!frame) continue;
    answered.push(frame.params!);
    host.result(frame);
  }
  expect(answered.map((p) => `${p.kind}:${p.last}`)).toEqual(["text:true", "binary:false", "binary:false", "binary:true", "close:true"]);
  expect(atob(answered[0]!.data as string)).toBe("hello");
  expect(answered.slice(1, 4).reduce((sum, p) => sum + atob(p.data as string).length, 0)).toBe(70 * 1024);
  expect(answered[4]).toMatchObject({ code: 4001, reason: "done" });
  await tick();
  expect(ws.bufferedAmount).toBe(4);
});

test("invalid arguments throw as the browser's do", () => {
  expect(() => new plugin.WebSocket("ftp://example.com/")).toThrow("ws or wss");
  expect(() => new plugin.WebSocket("wss://example.com/#x")).toThrow("fragment");
  expect(() => new plugin.WebSocket("wss://example.com/", ["a", "a"])).toThrow("duplicates");
  const ws = new plugin.WebSocket("wss://example.com/");
  expect(() => ws.close(1001)).toThrow("Invalid close code");
  expect(() => ws.close(1000, "x".repeat(124))).toThrow("123 bytes");
});

test("a failed connection fires error, then close 1006", async () => {
  const { ws, connect } = await opened();
  const seen: string[] = [];
  const log = console.error;
  console.error = () => {};
  ws.onerror = () => seen.push("error");
  ws.onclose = (e) => seen.push(`close ${e.code} ${e.wasClean}`);
  host.emit(connect, event("close", { code: 1006, error: "ConnectionFailed" }));
  host.result(connect);
  await tick();
  await tick();
  console.error = log;
  expect(seen).toEqual(["error", "close 1006 false"]);
});

test("closing while connecting stops the handshake", async () => {
  const { ws, connect } = await opened();
  const log = console.error;
  console.error = () => {};
  const closed = new Promise<CloseEvent>((resolve) => (ws.onclose = resolve));
  ws.close();
  const e = await closed;
  console.error = log;
  expect(e.code).toBe(1006);
  expect(host.cancels.map((frame) => frame.id)).toEqual([connect.id]);
});

test("a host without the plugin fails the connection", async () => {
  host.plugin = false;
  const log = console.error;
  const errors: string[] = [];
  console.error = (text: string) => errors.push(text);
  const ws = new plugin.WebSocket("wss://example.com/");
  const e = await new Promise<CloseEvent>((resolve) => (ws.onclose = resolve));
  console.error = log;
  expect(e.code).toBe(1006);
  expect(errors[0]).toContain("Host.use");
});
