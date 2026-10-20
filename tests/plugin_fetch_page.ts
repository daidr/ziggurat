import { connect } from "../packages/runtime/src/index";
import { fetch } from "../packages/plugin-fetch/src/index";

declare const chrome: { webview: { postMessage(message: string): void; addEventListener(type: "message", listener: (event: { data: unknown }) => void): void } };
const say = (message: string) => chrome.webview.postMessage(message);
const check = (condition: boolean, name: string) => {
  if (!condition) throw new Error(name);
};
const port = new Promise<number>((resolve) => {
  chrome.webview.addEventListener("message", ({ data }) => {
    if (typeof data === "string" && data.startsWith("pf-host:port:")) resolve(Number(data.slice(13)));
  });
});

let stage = "connect";
(async () => {
  await connect();
  say("pf-ready");
  const base = `http://127.0.0.1:${await port}`;

  stage = "json";
  const json = await fetch(`${base}/json`, { headers: { Origin: "https://app.example", "User-Agent": "notes/1" } });
  check(json.ok && json.status === 200, "JsonStatus");
  check(json.headers.get("x-seen") === "https://app.example notes/1", "ForbiddenHeadersSent");
  check(json.headers.get("set-cookie") === null, "SetCookieHidden");
  const value = (await json.json()) as { items: number[] };
  check(value.items.join(",") === "1,2,3", "JsonBody");

  stage = "post";
  const echo = await fetch(new Request(`${base}/echo`, { method: "POST", body: "plain body" }));
  check(echo.status === 201 && (await echo.text()) === "plain body", "PostBody");

  // A body too large for one message goes up in pieces.
  stage = "upload";
  const large = new Uint8Array(300_000).map((_, i) => (i * 7) % 256);
  const uploaded = await fetch(`${base}/echo`, { method: "PUT", body: large });
  const back = new Uint8Array(await uploaded.arrayBuffer());
  check(back.length === large.length && back.every((byte, i) => byte === large[i]), "UploadedBody");

  stage = "redirect";
  const hop = await fetch(`${base}/hop`);
  check(hop.redirected && hop.url === `${base}/json` && (await hop.json()).items.length === 3, "Redirected");
  const manual = await fetch(`${base}/hop`, { redirect: "manual" });
  check(manual.status === 302 && manual.headers.get("location") === "/json", "ManualRedirect");

  // Each part reaches the page before the server writes the next.
  stage = "stream";
  const stream = await fetch(`${base}/stream`);
  const reader = stream.body!.pipeThrough(new TextDecoderStream()).getReader();
  let text = "";
  for (let part = 0; part < 3; part++) {
    const { value, done } = await reader.read();
    check(!done, "StreamEnded");
    text += value;
    say(`pf-part:${part}`);
  }
  const end = await reader.read();
  check(end.done === true && text === "one two three ", "StreamText");

  stage = "big";
  const big = await fetch(`${base}/big`);
  const bytes = new Uint8Array(await big.arrayBuffer());
  check(bytes.length === 3_000_000, "BigLength");
  for (let i = 0; i < bytes.length; i += 9973) check(bytes[i] === (i * 31) % 251, "BigByte");

  stage = "unreachable";
  const failed = await fetch("http://127.0.0.1:1/").catch((error: unknown) => error);
  check(failed instanceof TypeError && failed.message.startsWith("fetch failed:"), "NetworkFailure");

  stage = "abort";
  const controller = new AbortController();
  const stalled = await fetch(`${base}/stall`, { signal: controller.signal });
  const reading = stalled.text();
  controller.abort(new Error("aborted"));
  const aborted = await reading.catch((error: unknown) => error);
  check(aborted instanceof Error && aborted.message === "aborted", "Abort");
  say("pf-done");
})().catch((error) => say(`pf-failed:${stage}: ${String(error)}`));
