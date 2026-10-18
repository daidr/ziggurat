import { createClient, RemoteError } from "./ipc_fixture";
declare const chrome: { webview: { postMessage(message: string): void; addEventListener(event: string, callback: (event: { data: string }) => void): void } };
let client: ReturnType<typeof createClient> | undefined;
let started = false;
const send = (message: string) => chrome.webview.postMessage(message);
chrome.webview.addEventListener("message", async (event) => {
  try {
    const packet = JSON.parse(event.data);
    if (packet.kind !== "hello") { client?.receive(event.data); return; }
    if (started) throw new Error("DuplicateHello");
    started = true;
    client = createClient(send, packet.session, { maxPending: 2, maxInFlight: 2 });
    let eventCount = 0;
    await new Promise<void>((resolve) => {
      const off = client!.on("changed", (value) => {
        if (value.path !== "文档.txt" || value.revision !== 7) throw new Error("WrongTypedEvent");
        eventCount++;
        off(); off();
        if (client!.listenerCount !== 0 || client!.subscriptionCount !== 0) throw new Error("SubscriptionLeak");
        resolve();
      });
      send("ipc-events-ready");
    });
    if (await client.add({ a: 19, b: 23 }).result !== 42) throw new Error("WrongSum");
    try { await client.add({ a: -1, b: 0 }).result; throw new Error("ExpectedDenied"); }
    catch (error) { if (!(error instanceof RemoteError) || error.code !== "denied") throw error; }
    const stream = client.watch({ topic: "news" });
    const values: string[] = [];
    for await (const item of stream) values.push(item);
    await stream.result;
    if (values.join(",") !== "one,two,three") throw new Error("WrongStream");
    const canceled = client.watch({ topic: "cancel" });
    const canceledResult = canceled.result.catch(error => error.code);
    canceled.cancel();
    if (await canceledResult !== "Cancelled") throw new Error("WrongCancellation");
    if (client.pendingCount !== 0) throw new Error("PendingLeak");
    if (eventCount !== 1) throw new Error("LateEventDelivered");
    client.close();
    send("ipc-done");
  } catch (error) { send("ipc-failed:" + String(error)); }
});
send("ipc-boot");
