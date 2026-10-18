import { expect, test } from "bun:test";
import { decodeChunk, resourceReadable, type ResourceCall, type ResourceFrame, type ResourceHead, type ResourceSummary } from "../src/resource_stream/client";

const head = (length: number | null = null): ResourceHead => ({ status: 200, mime: "application/octet-stream", headers: [], length });
const metadata = (value = head()): ResourceFrame => ({ head: value, body: null });
const bytes = (base64: string, count: number): ResourceFrame => ({ head: null, body: { base64, bytes: count } });
class Call implements ResourceCall {
  reads = 0;
  acknowledged = 0;
  cancelled = 0;
  queue: ResourceFrame[] = [];
  stopped = false;
  ended = false;
  waiter?: { resolve: (value: IteratorResult<ResourceFrame>) => void; reject: (error: unknown) => void };
  resolve!: (value: ResourceSummary) => void;
  reject!: (error: unknown) => void;
  result = new Promise<ResourceSummary>((resolve, reject) => { this.resolve = resolve; this.reject = reject; });
  constructor() { void this.result.catch(() => {}); }
  push(frame: ResourceFrame) {
    if (this.waiter) {
      const waiter = this.waiter; this.waiter = undefined;
      this.acknowledged++;
      waiter.resolve({ value: frame, done: false });
    } else this.queue.push(frame);
  }
  finish(summary: ResourceSummary) {
    this.ended = true;
    this.resolve(summary);
    if (this.waiter) { this.waiter.resolve({ value: undefined, done: true }); this.waiter = undefined; }
  }
  cancel() {
    if (this.stopped) return;
    this.stopped = true; this.cancelled++; this.queue.length = 0;
    const error = new Error("Cancelled");
    this.reject(error); this.waiter?.reject(error); this.waiter = undefined;
  }
  [Symbol.asyncIterator](): AsyncIterator<ResourceFrame> {
    return {
      next: () => {
        this.reads++;
        if (this.queue.length) { this.acknowledged++; return Promise.resolve({ value: this.queue.shift()!, done: false }); }
        if (this.stopped) return Promise.reject(new Error("Cancelled"));
        if (this.ended) return Promise.resolve({ value: undefined, done: true });
        if (this.waiter) return Promise.reject(new Error("ConcurrentRead"));
        return new Promise((resolve, reject) => { this.waiter = { resolve, reject }; });
      },
      return: () => { this.cancel(); return Promise.resolve({ value: undefined, done: true }); },
    };
  }
}

test("body pause sends no ACK until one reader pull; EOF validates byte and chunk totals", async () => {
  const call = new Call();
  call.push(metadata(head(3)));
  const response = resourceReadable(call);
  expect(await response.head).toEqual(head(3));
  call.push(bytes("AAEC", 3));
  await Promise.resolve();
  expect(call.reads).toBe(1);
  expect(call.acknowledged).toBe(1);
  const reader = response.body.getReader();
  expect((await reader.read()).value).toEqual(new Uint8Array([0, 1, 2]));
  expect(call.acknowledged).toBe(2);
  call.finish({ bytes: 3, chunks: 1 });
  expect((await reader.read()).done).toBe(true);
  expect(await response.completion).toEqual({ bytes: 3, chunks: 1 });
  expect(call.cancelled).toBe(0);
});

test("cancel before metadata or while a body pull waits cancels once and rejects local completion", async () => {
  for (const afterHead of [false, true]) {
    const call = new Call();
    if (afterHead) call.push(metadata());
    const response = resourceReadable(call);
    if (afterHead) await response.head;
    const reader = response.body.getReader();
    const pending = reader.read();
    await reader.cancel(new Error("StopResource"));
    expect((await pending).done).toBe(true);
    await expect(response.completion).rejects.toThrow("StopResource");
    if (!afterHead) await expect(response.head).rejects.toThrow("StopResource");
    expect(call.cancelled).toBe(1);
  }
});

test("transport failure after head rejects a paused body and completion without another pull", async () => {
  const call = new Call(); call.push(metadata());
  const response = resourceReadable(call);
  await response.head;
  call.reject(new Error("PageChanged"));
  await expect(response.completion).rejects.toThrow("PageChanged");
  expect(call.reads).toBe(1);
  await expect(response.body.getReader().read()).rejects.toThrow("PageChanged");
  expect(call.cancelled).toBe(1);
});

test("strict base64 has bounded output and rejects unused padding bits and alternate encodings", () => {
  for (const size of [1, 2, 3, 4, 16, 16 * 1024]) {
    const original = Uint8Array.from({ length: size }, (_, i) => (i * 31) & 255);
    expect(decodeChunk(Buffer.from(original).toString("base64"), size)).toEqual(original);
  }
  for (const [text, size] of [["AB==", 1], ["AAB=", 2], ["AA A", 3], ["AA", 1], ["AA==", 0], ["AA==", 2], ["AA-_", 3]] as const) {
    expect(() => decodeChunk(text, size)).toThrow();
  }
  expect(() => decodeChunk("A".repeat(4 * Math.ceil(16385 / 3)), 16385)).toThrow("InvalidChunk");
});

test("metadata is immutable and rejects CRLF, duplicate, framing and excess budgets", async () => {
  for (const value of [
    { ...head(), mime: "text/plain\r\nx: y" },
    { ...head(), headers: [{ name: "x-a", value: "a" }, { name: "X-A", value: "b" }] },
    { ...head(), headers: [{ name: "Content-Length", value: "1" }] },
    { ...head(), headers: [{ name: "x-a", value: "a\nb" }] },
    { ...head(), status: 204, length: 1 },
  ]) {
    const call = new Call(); call.push(metadata(value));
    const response = resourceReadable(call);
    await expect(response.head).rejects.toBeInstanceOf(Error);
    await expect(response.completion).rejects.toBeInstanceOf(Error);
    expect(call.cancelled).toBe(1);
  }
  const call = new Call(); call.push(metadata());
  const response = resourceReadable(call);
  const value = await response.head;
  expect(Object.isFrozen(value)).toBe(true);
  expect(Object.isFrozen(value.headers)).toBe(true);
  await response.body.cancel();
});

test("HEAD preserves representation length but forbids body; truncated and over-budget streams fail", async () => {
  const empty = new Call(); empty.push(metadata(head(100)));
  const response = resourceReadable(empty, { method: "head" });
  expect((await response.head).length).toBe(100);
  empty.finish({ bytes: 0, chunks: 0 });
  expect((await response.body.getReader().read()).done).toBe(true);
  expect(await response.completion).toEqual({ bytes: 0, chunks: 0 });
  for (const mode of ["head", "truncated", "budget", "second-head"]) {
    const call = new Call(); call.push(metadata(head(mode === "truncated" ? 3 : null)));
    const view = resourceReadable(call, mode === "head" ? { method: "head" } : mode === "budget" ? { maxTotalBytes: 1 } : {});
    await view.head;
    const reader = view.body.getReader();
    call.push(mode === "second-head" ? metadata() : bytes("AAE=", 2));
    if (mode === "truncated") {
      expect((await reader.read()).value).toEqual(new Uint8Array([0, 1]));
      call.finish({ bytes: 2, chunks: 1 });
    }
    await expect(reader.read()).rejects.toBeInstanceOf(Error);
    await expect(view.completion).rejects.toBeInstanceOf(Error);
    expect(call.cancelled).toBe(1);
  }
});

test("several reader requests still use one IPC next at a time", async () => {
  const call = new Call(); call.push(metadata());
  const response = resourceReadable(call);
  await response.head;
  const reader = response.body.getReader();
  const first = reader.read(), second = reader.read();
  call.push(bytes("YQ==", 1));
  expect((await first).value).toEqual(new Uint8Array([97]));
  call.push(bytes("Yg==", 1));
  expect((await second).value).toEqual(new Uint8Array([98]));
  call.finish({ bytes: 2, chunks: 2 });
  expect((await reader.read()).done).toBe(true);
  expect(await response.completion).toEqual({ bytes: 2, chunks: 2 });
});
