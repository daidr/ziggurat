import { afterEach, beforeEach, expect, test } from "bun:test";

type Listener = (event: { data: unknown }) => void;
type Frame = { session: string; kind: string; slot: number; id: number; method?: string; params?: Record<string, unknown>; sequence?: number };
type Answer = { parts?: unknown[]; value?: unknown; error?: { code: string; message: string } };

const runtimeSession = "0123456789abcdef0123456789abcdef";
const sqliteSession = "fedcba9876543210fedcba9876543210";

const cell = (type: string, fields: Record<string, unknown> = {}) => ({ type, integer: null, real: null, special: null, text: null, blob: null, ...fields });

/** A host whose SQLite plugin answers with scripted values. */
class FakeHost {
  listeners = new Set<Listener>();
  calls: Frame[] = [];
  respond: (frame: Frame) => Answer = (frame) => ({ value: frame.method === "open" ? 1 : null });

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
          services: { runtime: runtimeSession, "plugin:sqlite": sqliteSession },
        }),
      );
      return;
    }
    const frame = JSON.parse(message) as Frame;
    if (frame.session !== sqliteSession || frame.kind !== "call") return;
    this.calls.push(frame);
    const answer = this.respond(frame);
    queueMicrotask(() => {
      (answer.parts ?? []).forEach((value, index) =>
        this.post({ v: 1, session: sqliteSession, kind: "chunk", slot: frame.slot, id: frame.id, sequence: index + 1, value }),
      );
      if (answer.error) this.post({ v: 1, session: sqliteSession, kind: "error", slot: frame.slot, id: frame.id, error: answer.error });
      else this.post({ v: 1, session: sqliteSession, kind: "result", slot: frame.slot, id: frame.id, value: answer.value ?? null });
    });
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

test("parameters keep their types and results decode", async () => {
  host.respond = (frame) => {
    switch (frame.method) {
      case "open":
        return { value: 7 };
      case "execute":
        return { value: { changes: 1, lastInsertId: "9007199254740993" } };
      case "query":
        return {
          parts: [
            { columns: ["n", "n", "r", "s", "b"], rows: [[cell("integer", { integer: "1" }), cell("integer", { integer: "-9223372036854775808" }), cell("real", { real: 1.5 }), cell("text", { text: "a" }), cell("blob", { blob: "AAEC/w==" })]] },
            { columns: null, rows: [[cell("null"), cell("integer", { integer: "2" }), cell("real", { special: "-Infinity" }), cell("text", { text: "" }), cell("blob", { blob: "" })]] },
          ],
        };
      case "transaction":
        return { value: [] };
      default:
        return { value: null };
    }
  };
  const db = await plugin.open("data/app.db", { readOnly: true });
  expect(host.calls[0]!.params).toEqual({ name: "data/app.db", readOnly: true });
  const inserted = await db.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?, ?, ?)", [null, true, 12n, 1.25, "x", new Uint8Array([0, 1, 2, 255]), 3]);
  expect(inserted).toEqual({ changes: 1, lastInsertId: 9007199254740993n });
  expect(host.calls[1]!.params).toEqual({
    connection: 7,
    sql: "INSERT INTO t VALUES (?, ?, ?, ?, ?, ?, ?)",
    params: [cell("null"), cell("integer", { integer: "1" }), cell("integer", { integer: "12" }), cell("real", { real: 1.25 }), cell("text", { text: "x" }), cell("blob", { blob: "AAEC/w==" }), cell("integer", { integer: "3" })],
  });
  const rows = await db.query("SELECT * FROM t");
  expect(rows.columns).toEqual(["n", "n", "r", "s", "b"]);
  expect(rows.rows).toEqual([
    [1, -9223372036854775808n, 1.5, "a", new Uint8Array([0, 1, 2, 255])],
    [null, 2, -Infinity, "", new Uint8Array([])],
  ]);
  const results = await db.transaction([{ sql: "DELETE FROM t" }, { sql: "INSERT INTO t VALUES (?)", params: [false] }]);
  expect(host.calls[3]!.params).toEqual({ connection: 7, statements: [{ sql: "DELETE FROM t", params: [] }, { sql: "INSERT INTO t VALUES (?)", params: [cell("integer", { integer: "0" })] }] });
  expect(results).toEqual([]);
});

test("failures are SqliteErrors and a closed database refuses work", async () => {
  host.respond = (frame) => {
    if (frame.method === "open") return { value: 1 };
    if (frame.method === "execute") return { error: { code: "sqlite", message: "sqlite: no such table: t (code 1)" } };
    if (frame.method === "query") return { parts: [{ columns: ["n"], rows: [] }], error: { code: "limit", message: "sqlite: the result is too large" } };
    return { value: null };
  };
  const db = await plugin.open(":memory:");
  const failed = await db.execute("SELECT * FROM t").catch((error: unknown) => error);
  expect(failed).toBeInstanceOf(plugin.SqliteError);
  expect((failed as InstanceType<typeof plugin.SqliteError>).code).toBe("sqlite");
  await expect(db.query("SELECT 1")).rejects.toMatchObject({ code: "limit" });
  const closing = [db.close(), db.close()];
  await Promise.all(closing);
  await db.close();
  expect(host.calls.filter((frame) => frame.method === "closeDatabase")).toHaveLength(1);
  await expect(db.execute("SELECT 1")).rejects.toMatchObject({ code: "closed" });
});

test("a failed open rejects with its code", async () => {
  host.respond = () => ({ error: { code: "denied", message: "sqlite: database name must be a relative file name in the plugin's directory" } });
  await expect(plugin.open("../x.db")).rejects.toMatchObject({ name: "SqliteError", code: "denied" });
});

test("invalid parameters never reach the host", async () => {
  const db = await plugin.open(":memory:");
  const calls = host.calls.length;
  await expect(db.execute("SELECT ?", [NaN])).rejects.toBeInstanceOf(TypeError);
  await expect(db.execute("SELECT ?", [2 ** 60])).rejects.toBeInstanceOf(RangeError);
  await expect(db.execute("SELECT ?", [1n << 63n])).rejects.toBeInstanceOf(RangeError);
  await expect(db.execute("SELECT ?", [{} as never])).rejects.toBeInstanceOf(TypeError);
  expect(host.calls.length).toBe(calls);
});
