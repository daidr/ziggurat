import { connect, currentWindow, direction, isZiggurat, locale, onFileDrop, onLocaleChange, runtime, service } from "../packages/runtime/src/index";
import { createClient as createCounter } from "./ipc_fixture";

declare const chrome: { webview: { postMessage(message: string): void; addEventListener(type: "message", listener: (event: { data: unknown }) => void): void } };
// Plain strings are the application's own messages; the host's Host.receive
// reports them as foreign.
const say = (message: string) => chrome.webview.postMessage(message);
const check = (condition: boolean, name: string) => {
  if (!condition) throw new Error(name);
};
const next = <T>(register: (resolve: (value: T) => void) => () => void, ready: string) =>
  new Promise<T>((resolve) => {
    const off = register((value) => {
      off();
      resolve(value);
    });
    // Listeners subscribe in a microtask; announce readiness after it.
    setTimeout(() => say(ready), 0);
  });
const loaded = new Promise<void>((resolve) => (document.readyState === "complete" ? resolve() : addEventListener("load", () => resolve(), { once: true })));
const host = new Promise<string>((resolve) => {
  chrome.webview.addEventListener("message", ({ data }) => {
    if (typeof data === "string" && data.startsWith("pr-host:")) resolve(data.slice(8));
  });
});

(async () => {
  check(isZiggurat(), "NotInWindow");
  const rt = await connect();
  check(rt === runtime(), "RuntimeIdentity");
  check(rt.platform === (navigator.userAgent.includes("Windows") ? "win32" : "linux"), "WrongPlatform");
  check(rt.windowId === 7 && rt.locale === "en" && direction() === "ltr", "WrongConfiguration");
  check(rt.services.join(",") === "runtime,plugin:counter", "WrongServices");
  check(rt.preferences.accent === "#0a84ff" && rt.preferences.colorScheme === "dark", "WrongPreferences");
  check(document.documentElement.style.getPropertyValue("--ziggurat-accent") === "#0a84ff", "AccentVariable");

  await currentWindow.setTitle("Page runtime");
  await currentWindow.toggleMaximize();
  check(await currentWindow.isMaximized(), "NotMaximized");
  await currentWindow.unmaximize();
  check(!(await currentWindow.isMaximized()), "StillMaximized");

  const change = await next<[string, string]>((resolve) => onLocaleChange((tag, dir) => resolve([tag, dir])), "pr-locale");
  check(change[0] === "he" && change[1] === "rtl" && locale() === "he", "WrongLocaleChange");
  const drop = await next<{ paths: readonly string[]; x: number; y: number }>((resolve) => onFileDrop(resolve), "pr-drop");
  check(drop.paths.join("|") === "/tmp/a b.txt|/tmp/文件" && drop.x === 12 && drop.y === 34, "WrongDrop");

  const counter = await service("plugin:counter", createCounter);
  check((await counter.add({ a: 19, b: 23 }).result) === 42, "WrongPluginResult");
  check((await service("plugin:counter", createCounter)) === counter, "SecondPluginClient");

  await loaded;
  say("pr-find");
  check((await host) === "found", "FindFailed");
  check(document.querySelectorAll("mark[data-ziggurat-find]").length === 0, "MarksLeft");
  check(document.body.textContent!.includes("needle, Needle and NEEDLE"), "TextChanged");
  say("pr-close");
  // The reply arrives before the window closes.
  await currentWindow.close();
})().catch((error) => say("pr-failed:" + String(error)));
