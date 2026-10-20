import { afterEach, beforeEach, expect, test } from "bun:test";

type Listener = (event: { data: unknown }) => void;
type Frame = { session: string; kind: string; slot: number; id: number; method?: string; params?: Record<string, unknown>; sequence?: number };

const runtimeSession = "0123456789abcdef0123456789abcdef";
const fetchSession = "fedcba9876543210fedcba9876543210";

/** A host whose fetch plugin answers with scripted responses. */
class FakeHost {
  listeners = new Set<Listener>();
  calls: Frame[] = [];
  cancels: Frame[] = [];
  plugin = true;
  /** What to answer a call with; parts go out as chunks, then the end. */
  respond: (frame: Frame) => { parts: unknown[]; error?: { code: string; message: string }; hold?: boolean } = () => ({ parts: [] });
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
      const services: Record<string, string> = { runtime: runtimeSession };
      if (this.plugin) services["plugin:fetch"] = fetchSession;
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
    if (frame.session !== fetchSession) return;
    if (frame.kind === "cancel") this.cancels.push(frame);
    if (frame.kind !== "call") return;
    this.calls.push(frame);
    const answer = this.respond(frame);
    queueMicrotask(() => {
      answer.parts.forEach((value, index) => this.post({ v: 1, session: fetchSession, kind: "chunk", slot: frame.slot, id: frame.id, sequence: index + 1, value }));
      if (answer.hold) {
        this.held = frame;
        return;
      }
      this.finish(frame, answer.error);
    });
  }

  finish(frame: Frame, error?: { code: string; message: string }) {
    if (error) this.post({ v: 1, session: fetchSession, kind: "error", slot: frame.slot, id: frame.id, error });
    else this.post({ v: 1, session: fetchSession, kind: "result", slot: frame.slot, id: frame.id, value: null });
  }
}

const head = (status = 200, headers: [string, string][] = [["content-type", "text/plain"]], extra: Record<string, unknown> = {}) => ({
  head: { status, statusText: status === 200 ? "OK" : "", url: "https://api.example.com/items", redirected: false, headers: headers.map(([name, value]) => ({ name, value })), ...extra },
  chunk: null,
});
const chunk = (text: string) => ({ head: null, chunk: btoa(text) });

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

test("a response streams its head and body from the host", async () => {
  host.respond = () => ({ parts: [head(200, [["content-type", "text/plain"], ["x-kind", "items"]], { redirected: true }), chunk("hello "), chunk("world")] });
  const res = await plugin.fetch("https://api.example.com/items", { headers: { Origin: "https://app.example", "User-Agent": "notes/1" } });
  expect(res.status).toBe(200);
  expect(res.ok).toBe(true);
  expect(res.statusText).toBe("OK");
  expect(res.headers.get("x-kind")).toBe("items");
  expect(res.url).toBe("https://api.example.com/items");
  expect(res.redirected).toBe(true);
  expect(await res.text()).toBe("hello world");
  const params = host.calls[0]!.params!;
  expect(params.method).toBe("GET");
  expect(params.body).toBeNull();
  expect(params.redirect).toBe("follow");
  expect(params.headers).toContainEqual({ name: "origin", value: "https://app.example" });
  expect(params.headers).toContainEqual({ name: "user-agent", value: "notes/1" });
});

test("bodies are sent whole with the content type fetch gives them", async () => {
  host.respond = () => ({ parts: [head(201)] });
  const res = await plugin.fetch(new URL("https://api.example.com/items"), { method: "post", body: new Blob([JSON.stringify({ name: "Ada" })], { type: "application/json" }), redirect: "manual" });
  expect(res.status).toBe(201);
  expect(await res.text()).toBe("");
  const params = host.calls[0]!.params!;
  expect(params.method).toBe("POST");
  expect(atob(params.body as string)).toBe('{"name":"Ada"}');
  expect(params.redirect).toBe("manual");
  const type = (params.headers as { name: string; value: string }[]).find((header) => header.name === "content-type");
  expect(type?.value.startsWith("application/json")).toBe(true);
  await expect(plugin.fetch("https://api.example.com/", { method: "GET", body: "x" })).rejects.toThrow("cannot have a body");
});

test("large bodies go first as upload pieces", async () => {
  const pieces: string[] = [];
  host.respond = (frame) => {
    if (frame.method === "upload") {
      pieces.push(atob(frame.params!.data as string));
      return { parts: [] };
    }
    return { parts: [head(200)] };
  };
  const big = "x".repeat(100_000);
  const res = await plugin.fetch("https://api.example.com/upload", { method: "PUT", body: big });
  expect(res.status).toBe(200);
  const call = host.calls.find((frame) => frame.method === "fetch")!;
  expect(call.params!.body).toBeNull();
  expect(typeof call.params!.upload).toBe("number");
  expect(pieces.length).toBe(3);
  expect(pieces.join("")).toBe(big);
});

test("null-body statuses and HEAD give no body; statuses outside Response's range are kept", async () => {
  host.respond = () => ({ parts: [head(204)] });
  const empty = await plugin.fetch("https://api.example.com/");
  expect(empty.body).toBeNull();
  host.respond = () => ({ parts: [head(101, [])] });
  const upgraded = await plugin.fetch("https://api.example.com/");
  expect(upgraded.status).toBe(101);
});

test("failures reject with a TypeError that says why", async () => {
  host.respond = () => ({ parts: [], error: { code: "failed", message: "ConnectionFailed" } });
  const error = await plugin.fetch("https://unreachable.example/").catch((e: unknown) => e);
  expect(error).toBeInstanceOf(TypeError);
  expect((error as Error).message).toBe("fetch failed: ConnectionFailed");
  // A failure after the head errors the body.
  host.respond = () => ({ parts: [head(), chunk("part")], error: { code: "failed", message: "ConnectionFailed" } });
  const res = await plugin.fetch("https://api.example.com/");
  await expect(res.text()).rejects.toThrow("fetch failed: ConnectionFailed");
});

test("aborting cancels the call in the host, before and after the head", async () => {
  host.respond = () => ({ parts: [], hold: true });
  const before = new AbortController();
  const pending = plugin.fetch("https://slow.example/", { signal: before.signal });
  await new Promise((resolve) => setTimeout(resolve, 0));
  before.abort(new Error("stop"));
  await expect(pending).rejects.toThrow("stop");
  expect(host.cancels.length).toBe(1);

  host.respond = () => ({ parts: [head()], hold: true });
  const after = new AbortController();
  const res = await plugin.fetch("https://slow.example/", { signal: after.signal });
  const reading = res.text();
  after.abort(new Error("later"));
  await expect(reading).rejects.toThrow("later");
  expect(host.cancels.length).toBe(2);
  expect(() => plugin.fetch("https://slow.example/", { signal: after.signal })).toThrow();
});

test("cancelling the body cancels the call", async () => {
  host.respond = () => ({ parts: [head(), chunk("first")], hold: true });
  const res = await plugin.fetch("https://api.example.com/stream");
  const reader = res.body!.getReader();
  expect(new TextDecoder().decode((await reader.read()).value)).toBe("first");
  await reader.cancel();
  expect(host.cancels.length).toBe(1);
});

test("other schemes go to the WebView's fetch", async () => {
  const seen: unknown[] = [];
  const native = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    seen.push(String(input));
    return new Response("native");
  }) as typeof fetch;
  try {
    const res = await plugin.fetch("data:text/plain,hi");
    expect(await res.text()).toBe("native");
    expect(seen).toEqual(["data:text/plain,hi"]);
    expect(host.calls.length).toBe(0);
  } finally {
    globalThis.fetch = native;
  }
});

test("a host without the plugin says to register it", async () => {
  host.plugin = false;
  await expect(plugin.fetch("https://api.example.com/")).rejects.toThrow("register it with Host.use");
});
