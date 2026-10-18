import { describe, test, expect } from "bun:test";
import { createClient, LocalError, RemoteError } from "./ipc_fixture";

const session = "00000000000000000000000000000001";
function setup(options = { maxPending: 2, maxInFlight: 2 }) {
  const posted: any[] = [];
  const client = createClient((message) => posted.push(JSON.parse(message)), session, options);
  const reply = (request: any, fields: object) => client.receive(JSON.stringify({ v: 1, session, slot: request.slot, id: request.id, ...fields }));
  return { client, posted, reply };
}

describe("generated client", () => {
  test("typed results/errors, pending bounds and reused slots", async () => {
    const { client, posted, reply } = setup();
    const first = client.add({ a: 2, b: 3 });
    const second = client.add({ a: 4, b: 5 });
    expect(client.pendingCount).toBe(2);
    expect(() => client.add({ a: 0, b: 0 })).toThrow("Full");
    reply(posted[0], { kind: "result", value: 5 });
    expect(await first.result).toBe(5);
    const third = client.add({ a: 7, b: 8 });
    expect(posted[2].slot).toBe(posted[0].slot);
    reply(posted[0], { kind: "result", value: 999 });
    expect(client.pendingCount).toBe(2);
    reply(posted[1], { kind: "error", error: { code: "denied", message: "no" } });
    await expect(second.result).rejects.toBeInstanceOf(RemoteError);
    expect(second.error?.code).toBe("denied");
    reply(posted[2], { kind: "result", value: 15 });
    expect(await third.result).toBe(15);
    expect(client.pendingCount).toBe(0);
  });

  test("stream chunks acknowledge consumption, with one outstanding next", async () => {
    const { client, posted, reply } = setup();
    const stream = client.watch({ topic: "news" });
    const request = posted[0];
    reply(request, { kind: "chunk", sequence: 1, value: "a" });
    reply(request, { kind: "chunk", sequence: 2, value: "b" });
    expect(posted).toHaveLength(1);
    const iterator = stream[Symbol.asyncIterator]();
    expect(await iterator.next()).toEqual({ done: false, value: "a" });
    expect(posted[1]).toMatchObject({ kind: "ack", sequence: 1 });
    expect(await iterator.next()).toEqual({ done: false, value: "b" });
    const waiting = iterator.next();
    await expect(iterator.next()).rejects.toThrow("ConcurrentRead");
    reply(request, { kind: "chunk", sequence: 3, value: "c" });
    expect(await waiting).toEqual({ done: false, value: "c" });
    reply(request, { kind: "result" });
    expect(await stream.result).toBeUndefined();
    expect(await iterator.next()).toEqual({ done: true, value: undefined });
  });

  test("cancel and stale sessions cannot finish a newer request", async () => {
    const { client, posted, reply } = setup();
    const first = client.add({ a: 1, b: 2 });
    first.cancel();
    await expect(first.result).rejects.toThrow("Cancelled");
    expect(posted[1].kind).toBe("cancel");
    const second = client.add({ a: 3, b: 4 });
    reply(posted[2], { kind: "result", value: 999, session: "00000000000000000000000000000002" });
    reply(posted[0], { kind: "result", value: 999 });
    expect(client.pendingCount).toBe(1);
    reply(posted[2], { kind: "result", value: 7 });
    expect(await second.result).toBe(7);
  });

  test("wrong result types and stream overflow fail the connection", async () => {
    const { client, posted, reply } = setup();
    const call = client.add({ a: 1, b: 2 });
    reply(posted[0], { kind: "result", value: "3" });
    await expect(call.result).rejects.toThrow("InvalidResult");
    expect(() => client.add({ a: 1, b: 2 })).toThrow("Closed");
    const other = setup();
    const stream = other.client.watch({ topic: "x" });
    for (let sequence = 1; sequence <= 3; sequence++) other.reply(other.posted[0], { kind: "chunk", sequence, value: "x" });
    await expect(stream.result).rejects.toThrow("InvalidChunk");
  });

  test("invalid input, void methods, close and transport failure are concrete", async () => {
    const { client, posted, reply } = setup();
    expect(() => client.add({ a: "1", b: 2 } as never)).toThrow("InvalidParams");
    expect(posted).toHaveLength(0);
    const ping = client.ping();
    reply(posted[0], { kind: "result", value: { ok: true, label: null } });
    expect(await ping.result).toEqual({ ok: true, label: null });
    const stream = client.watch({ topic: "x" });
    const waiting = stream[Symbol.asyncIterator]().next();
    client.close();
    await expect(waiting).rejects.toThrow("Closed");
    await expect(stream.result).rejects.toThrow("Closed");
    expect(posted.at(-1)).toMatchObject({ kind: "cancel" });
    const broken = createClient(() => { throw new Error("offline"); }, session);
    await expect(broken.add({ a: 1, b: 2 }).result).rejects.toThrow("offline");
    expect(broken.pendingCount).toBe(0);
    expect(() => broken.ping()).toThrow("Closed");
    expect(LocalError).toBeDefined();
  });

  test("generated shape validation handles arrays, fixed UTF-8 and defaults", async () => {
    const { client, posted, reply } = setup();
    const params = { flag: true, mode: "tiny" as const, weights: [1, 2] as const,
      label: "hi", names: ["a", "b"], optional: undefined };
    const call = client.inspect(params);
    reply(posted[0], { kind: "result", value: { ok: true } });
    expect(await call.result).toEqual({ ok: true });
    expect(() => client.inspect({ ...params, weights: [1] } as never)).toThrow("InvalidParams");
    expect(() => client.inspect({ ...params, weights: [1e100, 1] })).toThrow("InvalidParams");
    expect(() => client.inspect({ ...params, label: "中" })).toThrow("InvalidParams");
    expect(() => client.inspect({ ...params, mode: "other" } as never)).toThrow("InvalidParams");
  });
});
