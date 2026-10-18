import { createClient } from "./resource_producer_fixture";
import { resourceReadable } from "../src/resource_stream/client";
declare const chrome: { webview: { postMessage(message: string): void; addEventListener(event: string, callback: (event: { data: string }) => void): void } };
const send = (message: string) => chrome.webview.postMessage(message);
const checks = (condition: unknown, label: string) => { if (!condition) throw Error(label); };
const waiting = new Map<string, () => void>();
let client: ReturnType<typeof createClient>;
let duplicate = false;
const command = (name: string) => new Promise<void>(resolve => waiting.set(name, resolve));
const transport = (message: string) => {
  send(message);
  const value = JSON.parse(message);
  if (value.kind === "ack" && value.sequence === 2 && !duplicate) { duplicate = true; send(message); }
};
async function read(path: string, options: { head?: boolean; pause?: string } = {}) {
  const stream = resourceReadable(client.open({ path }), { method: options.head ? "head" : "get", maxChunkBytes: 64, maxTotalBytes: 256 });
  const head = await stream.head;
  checks(head.mime === "application/octet-stream", "mime");
  if (options.pause) {
    let complete = false;
    void stream.completion.then(() => { complete = true; });
    const ready = command("resume");
    send(options.pause);
    await ready;
    checks(!complete, "paused completion must wait for reader drain");
  }
  const reader = stream.body.getReader();
  let count = 0, total = 0;
  for (;;) {
    const item = await reader.read();
    if (item.done) break;
    checks(item.value.length === 64 && item.value.every(value => value === count + 1), "body order/bytes");
    count++; total += item.value.length;
  }
  const summary = await stream.completion;
  checks(summary.bytes === total && summary.chunks === count, "summary");
  return { count, total, head };
}
async function run(stage: string) {
  if (stage === "allocator") {
    const stream = resourceReadable(client.open({ path: "allocator" }));
    void stream.head.catch(() => {}); void stream.completion.catch(() => {});
    return;
  }
  if (stage === "after_nav") {
    checks((await read("zero")).count === 0, "new page zero");
    client.close(); send("suite-done"); return;
  }
  if (stage === "quit") {
    const stream = resourceReadable(client.open({ path: "quit" }), { maxChunkBytes: 64, maxTotalBytes: 256 });
    void stream.completion.catch(() => {});
    await stream.head;
    send("quit-paused");
    return;
  }
  checks((await read("normal", { pause: "paused" })).total === 256, "normal total");
  checks((await read("zero", { pause: "zero-head" })).count === 0, "zero count");
  checks((await read("head", { head: true, pause: "head-only" })).count === 0, "head count");
  const denied = resourceReadable(client.open({ path: "denied" }));
  const deniedResult = denied.completion.catch(error => error.code);
  try { await denied.head; throw Error("denied resolved"); } catch (error) { checks((error as { code: string }).code === "denied", "denied code"); }
  checks(await deniedResult === "denied", "denied completion");
  const canceled = resourceReadable(client.open({ path: "cancel" }), { maxChunkBytes: 64, maxTotalBytes: 256 });
  void canceled.completion.catch(() => {});
  await canceled.head;
  await canceled.body.cancel("fixture cancel");
  const parked = command("parked"); send("park-now"); await parked;
  checks((await read("park")).total === 256, "park body");
  send("park-done");
  const pending = resourceReadable(client.open({ path: "navigate" }), { maxChunkBytes: 64, maxTotalBytes: 256 });
  void pending.completion.catch(() => {});
  await pending.head;
  send("navigate-now");
}
chrome.webview.addEventListener("message", event => {
  try {
    if (event.data === "resume" || event.data === "parked") {
      const resolve = waiting.get(event.data); checks(resolve, "unexpected command"); waiting.delete(event.data); resolve!(); return;
    }
    const value = JSON.parse(event.data);
    if (value.kind === "hello") {
      client = createClient(transport, value.session, { maxPending: 4, maxInFlight: 1 });
      void run(value.stage).catch(error => send("producer-failed:" + String(error)));
    } else client.receive(event.data);
  } catch (error) { send("producer-failed:" + String(error)); }
});
send("producer-boot");
