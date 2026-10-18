import { describe, expect, test } from "bun:test";
import { createClient, LocalError } from "./ipc_fixture";

const session = "00000000000000000000000000000001";
const other = "00000000000000000000000000000002";
const frame = (control: any, value: unknown, extra: object = {}) => JSON.stringify({
  v: 1, session, kind: "event", event: control.event, subscription: control.subscription, value, ...extra,
});
function setup(options: Parameters<typeof createClient>[2] = {}) {
  const posted: any[] = [];
  const client = createClient((message) => { posted.push(JSON.parse(message)); }, session, options);
  return { client, posted };
}

describe("generated typed events", () => {
  test("listeners share one wire subscription and have independent idempotent removal", () => {
    const { client, posted } = setup();
    const values: string[] = [];
    const callback = (value: { path: string; revision: number }) => { values.push(`${value.path}:${value.revision}`); };
    const first = client.on("changed", callback);
    const second = client.on("changed", callback);
    expect(client.listenerCount).toBe(2);
    expect(client.subscriptionCount).toBe(1);
    expect(client.pendingCount).toBe(0);
    expect(posted).toHaveLength(1);
    expect(posted[0]).toMatchObject({ kind: "subscribe", event: "changed", subscription: 1 });
    expect(posted[0].slot).toBeUndefined();
    expect(posted[0].id).toBeUndefined();
    client.receive(frame(posted[0], { path: "文档", revision: 1 }));
    expect(values).toEqual(["文档:1", "文档:1"]);
    first(); first();
    expect(client.listenerCount).toBe(1);
    expect(posted).toHaveLength(1);
    client.receive(frame(posted[0], { path: "one", revision: 2 }));
    expect(values.at(-1)).toBe("one:2");
    second(); second();
    expect(posted).toHaveLength(2);
    expect(posted[1]).toMatchObject({ kind: "unsubscribe", subscription: 1 });
    expect(client.listenerCount).toBe(0);
    expect(client.subscriptionCount).toBe(0);
    client.receive(frame(posted[0], { path: "late", revision: 3 }));
    expect(values).toHaveLength(3);
  });

  test("foreign sessions and old subscription generations cannot reach replacement listeners", () => {
    const { client, posted } = setup();
    let old = 0, fresh = 0;
    const off = client.on("reset", () => { old++; });
    off();
    client.on("reset", () => { fresh++; });
    const replacement = posted.at(-1);
    expect(replacement.subscription).toBe(2);
    client.receive(frame(posted[0], null));
    client.receive(frame(replacement, null, { session: other }));
    expect(old).toBe(0); expect(fresh).toBe(0);
    client.receive(frame(replacement, null));
    expect(fresh).toBe(1);
    client.close();
    client.receive(frame(replacement, null));
    expect(fresh).toBe(1);
    expect(client.listenerCount).toBe(0);
    expect(() => client.on("reset", () => {})).toThrow("Closed");
    const reloaded = createClient(() => {}, other);
    let afterReload = 0;
    reloaded.on("reset", () => { afterReload++; });
    reloaded.receive(frame(replacement, null));
    expect(afterReload).toBe(0);
  });

  test("listener and subscription capacity fail without taking state or RPC slots", () => {
    const { client, posted } = setup({ maxPending: 1, maxEventListeners: 2, maxSubscriptions: 1 });
    const first = client.on("reset", () => {});
    client.on("reset", () => {});
    expect(() => client.on("reset", () => {})).toThrow("ListenerFull");
    first();
    expect(() => client.on("status", () => {})).toThrow("SubscriptionFull");
    expect(client.listenerCount).toBe(1);
    expect(client.subscriptionCount).toBe(1);
    expect(posted).toHaveLength(1);
    client.close();
  });

  test("event traffic and stream acknowledgements do not consume each other's identity or credit", async () => {
    const { client, posted } = setup({ maxPending: 1, maxInFlight: 1 });
    let status = "";
    client.on("status", (value) => { status = value; });
    const stream = client.watch({ topic: "news" });
    const request = posted[1];
    expect(request.id).toBe(1);
    client.receive(frame(posted[0], "busy"));
    expect(status).toBe("busy");
    expect(client.pendingCount).toBe(1);
    client.receive(JSON.stringify({ v: 1, session, kind: "chunk", slot: request.slot, id: request.id, sequence: 1, value: "one" }));
    const iterator = stream[Symbol.asyncIterator]();
    expect(await iterator.next()).toEqual({ done: false, value: "one" });
    expect(posted.at(-1)).toMatchObject({ kind: "ack", id: 1, sequence: 1 });
    client.receive(JSON.stringify({ v: 1, session, kind: "result", slot: request.slot, id: request.id }));
    await stream.result;
    const next = client.add({ a: 1, b: 2 });
    expect(posted.at(-1).id).toBe(2);
    client.close();
    await expect(next.result).rejects.toThrow("Closed");
  });

  test("removal takes effect during dispatch and additions wait for the next event", () => {
    const { client, posted } = setup();
    const calls: string[] = [];
    let second = () => {}, added = false;
    client.on("reset", () => {
      calls.push("first"); second();
      if (!added) { added = true; client.on("reset", () => { calls.push("new"); }); }
    });
    second = client.on("reset", () => { calls.push("removed"); });
    client.receive(frame(posted[0], null));
    expect(calls).toEqual(["first"]);
    client.receive(frame(posted[0], null));
    expect(calls).toEqual(["first", "first", "new"]);
    client.close();
  });

  test("slot reuse preserves registration order and old removal closures cannot remove replacements", () => {
    const { client, posted } = setup();
    const calls: string[] = [];
    const first = client.on("reset", () => { calls.push("old"); });
    client.on("reset", () => { calls.push("second"); });
    first();
    client.on("reset", () => { calls.push("new"); });
    first();
    client.receive(frame(posted[0], null));
    expect(calls).toEqual(["second", "new"]);
    expect(client.listenerCount).toBe(2);
    client.close();
  });

  test("callback errors preserve the connection, and close stops remaining callbacks", () => {
    const { client, posted } = setup();
    let count = 0;
    const off = client.on("reset", () => { throw new Error("consumer failure"); });
    client.on("reset", () => { count++; });
    expect(() => client.receive(frame(posted[0], null))).toThrow("consumer failure");
    expect(count).toBe(1);
    expect(client.listenerCount).toBe(2);
    off();
    client.receive(frame(posted[0], null));
    expect(count).toBe(2);
    const closing = setup();
    closing.client.on("reset", () => { closing.client.close(); });
    closing.client.on("reset", () => { count++; });
    closing.client.receive(frame(closing.posted[0], null));
    expect(count).toBe(2);
    expect(closing.client.listenerCount).toBe(0);
    expect(closing.client.subscriptionCount).toBe(0);
    expect(closing.posted.at(-1).kind).toBe("unsubscribe");
  });

  test("nested event receive is explicit and bounded while a synchronous RPC reply is allowed", async () => {
    const { client, posted } = setup();
    let count = 0;
    const call = client.add({ a: 1, b: 2 });
    const request = posted[0];
    client.on("reset", () => {
      count++;
      expect(() => client.receive(frame(posted[1], null))).toThrow("ReentrantEvent");
      client.receive(JSON.stringify({ v: 1, session, kind: "result", id: request.id, slot: request.slot, value: 3 }));
    });
    client.receive(frame(posted[1], null));
    expect(count).toBe(1);
    expect(await call.result).toBe(3);
    expect(client.listenerCount).toBe(1);
    client.close();
  });

  test("invalid event shapes close outstanding RPCs and discard all registrations", async () => {
    for (const value of ["wrong", { path: "x", revision: -1 }, { path: "x", revision: 1, extra: true }]) {
      const { client, posted } = setup();
      client.on("changed", () => { throw new Error("must not call"); });
      const call = client.add({ a: 0, b: 1 });
      client.receive(frame(posted[0], value));
      await expect(call.result).rejects.toThrow("InvalidEvent");
      expect(client.listenerCount).toBe(0);
      expect(client.subscriptionCount).toBe(0);
      expect(client.pendingCount).toBe(0);
    }
    expect(() => setup().client.on("__proto__" as never, () => {})).toThrow("InvalidEvent");
  });

  test("failed subscribe and unsubscribe have bounded rollback and transport closure", async () => {
    const sized = setup({ maxMessageBytes: 100 });
    expect(() => sized.client.on("changed", () => {})).toThrow("MessageTooLarge");
    expect(sized.client.listenerCount).toBe(0);
    expect(sized.client.subscriptionCount).toBe(0);
    expect(sized.posted).toHaveLength(0);
    let fail = false;
    const client = createClient(() => { if (fail) throw new Error("offline"); }, session);
    const call = client.add({ a: 1, b: 2 });
    const off = client.on("reset", () => {});
    fail = true;
    expect(off).toThrow("offline");
    await expect(call.result).rejects.toThrow("offline");
    expect(client.listenerCount).toBe(0);
    expect(client.subscriptionCount).toBe(0);
    off(); client.close();
    expect(LocalError).toBeDefined();
  });
});

// These assertions are checked by tsc --strict; Bun never executes them.
if (false) {
  const client = createClient(() => {}, session);
  client.on("changed", (value) => { const revision: number = value.revision; void revision; });
  client.on("reset", (value) => { const empty: undefined = value; void empty; });
  // @ts-expect-error Event names come from the Zig schema.
  client.on("missing", () => {});
  // @ts-expect-error Payload types come from the Zig schema.
  client.on("changed", (value: string) => { void value; });
  client.on("status", (value) => {
    // @ts-expect-error Only the declared enum cases are possible.
    const impossible: "other" = value; void impossible;
  });
}
