import { connect } from "../packages/runtime/src/index";
import { WebSocket } from "../packages/plugin-websocket/src/index";

declare const chrome: { webview: { postMessage(message: string): void; addEventListener(type: "message", listener: (event: { data: unknown }) => void): void } };
const say = (message: string) => chrome.webview.postMessage(message);
const check = (condition: boolean, name: string) => {
  if (!condition) throw new Error(name);
};
const port = new Promise<number>((resolve) => {
  chrome.webview.addEventListener("message", ({ data }) => {
    if (typeof data === "string" && data.startsWith("pw-host:port:")) resolve(Number(data.slice(13)));
  });
});

/** The next event of `type` on the socket. */
function next<K extends "open" | "message" | "close">(ws: WebSocket, type: K): Promise<K extends "message" ? MessageEvent : K extends "close" ? CloseEvent : Event> {
  return new Promise((resolve) => ws.addEventListener(type, (e) => resolve(e as never), { once: true }));
}

let stage = "connect";
(async () => {
  await connect();
  say("pw-ready");
  const url = `ws://127.0.0.1:${await port}/live?room=1`;

  stage = "open";
  // Headers the browser's WebSocket cannot send reach the server.
  const ws = new WebSocket(url, ["chat.v1", "chat.v2"], { headers: { Authorization: "Bearer token", Origin: "https://app.example" } });
  ws.binaryType = "arraybuffer";
  await next(ws, "open");
  check(ws.readyState === WebSocket.OPEN && ws.protocol === "chat.v2", "Protocol");

  stage = "text";
  ws.send("héllo");
  const text = await next(ws, "message");
  check(text.data === "héllo", "TextEcho");

  // A message larger than a piece goes and comes back whole.
  stage = "binary";
  const large = new Uint8Array(300_000).map((_, i) => (i * 7) % 256);
  ws.send(large);
  check(ws.bufferedAmount === large.length, "BufferedAmount");
  const binary = await next(ws, "message");
  const back = new Uint8Array(binary.data as ArrayBuffer);
  check(back.length === large.length && back.every((byte, i) => byte === large[i]), "BinaryEcho");
  check(ws.bufferedAmount === 0, "BufferedDrained");

  stage = "close";
  const closed = next(ws, "close");
  ws.close(4000, "done");
  check(ws.readyState === WebSocket.CLOSING, "Closing");
  const e = await closed;
  check(e.code === 4000 && e.reason === "bye" && e.wasClean, "CleanClose");

  // Nothing listens on port 1.
  stage = "refused";
  const refused = new WebSocket("ws://127.0.0.1:1/");
  let errored = false;
  refused.onerror = () => (errored = true);
  const failed = await next(refused, "close");
  check(errored && failed.code === 1006 && !failed.wasClean, "Refused");

  say("pw-done");
})().catch((error) => say(`pw-failed:${stage}:${error instanceof Error ? error.message : String(error)}`));
