import { connect } from "../packages/runtime/src/index";
import { watch, WatchError } from "../packages/plugin-watch/src/index";

declare const chrome: { webview: { postMessage(message: string): void; addEventListener(type: "message", listener: (event: { data: unknown }) => void): void } };
const say = (message: string) => chrome.webview.postMessage(message);
const check = (condition: boolean, name: string) => {
  if (!condition) throw new Error(name);
};
const host = (expected: string) =>
  new Promise<void>((resolve) => {
    chrome.webview.addEventListener("message", ({ data }) => {
      if (data === expected) resolve();
    });
  });
const describe = (events: { op: string; path: string; oldPath?: string }[]) =>
  events.map((event) => (event.oldPath ? `${event.op} ${event.oldPath} ${event.path}` : `${event.op} ${event.path}`)).sort().join(",");

let stage = "connect";
(async () => {
  await connect();

  stage = "denied";
  const denied = await watch("elsewhere").catch((error: unknown) => error);
  check(denied instanceof WatchError && denied.code === "denied", "Denied");

  stage = "watch";
  const watcher = await watch("project", { recursive: true, debounceMs: 30 });
  const changes = watcher[Symbol.asyncIterator]();
  const written = host("pw-host:written");
  say("pw-ready");
  await written;

  stage = "changes";
  const seen: string[] = [];
  while (seen.length < 3) {
    const next = await changes.next();
    check(!next.done, "WatchEnded");
    seen.push(...describe(next.value).split(","));
  }
  check(seen.sort().join(",") === "create notes/b.md,rename notes/a.md notes/c.md,write notes/d.md", `Changes ${seen.join(",")}`);

  stage = "close";
  await watcher.close();
  await watcher.closed;
  say("pw-done");
})().catch((error) => say(`pw-failed:${stage}: ${String(error)}`));
