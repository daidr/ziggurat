/**
 * The page side of the Ziggurat page runtime: the platform, the hosting
 * window's controls, the app's language and the desktop's preferences, and
 * connections to the host's plugins.
 *
 * ```ts
 * import { connect, currentWindow, onLocaleChange } from "@ziggurat/runtime";
 *
 * const runtime = await connect();
 * if (runtime.platform === "win32") document.documentElement.classList.add("windows");
 * await currentWindow.toggleMaximize();
 * ```
 *
 * The host answers the page's first message with its configuration, so
 * everything but `isZiggurat` waits for {@link connect}.
 *
 * @module
 */
import { createClient as createRuntimeClient, type Client as RuntimeClient, type Events } from "./generated/runtime";

/** The operating system, with Node.js's `process.platform` names. */
export type Platform = "win32" | "linux" | "darwin";
/** The direction a language is written in. */
export type Direction = "ltr" | "rtl";

/** The desktop's appearance and accessibility settings. */
export interface Preferences {
  /** The desktop's accent color as "#rrggbb", or null where it has none. */
  readonly accent: string | null;
  readonly colorScheme: "light" | "dark" | "unknown";
  readonly reduceMotion: boolean;
  /** Whether the desktop asks for opaque surfaces; false where it cannot say. */
  readonly reduceTransparency: boolean;
  readonly highContrast: boolean;
  /** How many times larger than usual text should be; 1 is usual. */
  readonly textScale: number;
}

/** Files dropped on the window, with the paths DOM drop events do not tell. */
export interface FileDrop {
  readonly paths: readonly string[];
  /** Where they were dropped, in CSS pixels, like `clientX`/`clientY`. */
  readonly x: number;
  readonly y: number;
}

/** The document a document window shows, as the host describes it. */
export interface DocumentState {
  /** The file name, or a name such as "Untitled 2" while untitled. */
  readonly name: string;
  /** The file's path; "" while the document is untitled. */
  readonly path: string;
  readonly edited: boolean;
  readonly readOnly: boolean;
  /** Another app changed the file while the document had unsaved changes. */
  readonly conflict: boolean;
  /** The file was deleted; saving writes it again. */
  readonly deleted: boolean;
}

/** What the host told the page when it connected, kept current since. */
export interface Runtime {
  readonly platform: Platform;
  /** The hosting window's id, unique among the app's open windows. */
  readonly windowId: number;
  /** The framework's version. */
  readonly version: string;
  /** The language the app shows, a BCP 47 tag such as "en" or "zh-Hant". */
  readonly locale: string;
  readonly dir: Direction;
  readonly preferences: Preferences;
  /** The services the host offers this page: "runtime" and "plugin:<name>". */
  readonly services: readonly string[];
}

/** Controls of the window hosting the page, e.g. for a custom title bar. */
export interface WindowControls {
  minimize(): Promise<void>;
  maximize(): Promise<void>;
  unmaximize(): Promise<void>;
  toggleMaximize(): Promise<void>;
  isMaximized(): Promise<boolean>;
  toggleFullScreen(): Promise<void>;
  /** Asks the window to close; the app may still cancel it. */
  close(): Promise<void>;
  setTitle(title: string): Promise<void>;
}

/** Limits a generated client takes; they must match the host's. */
export interface ClientLimits {
  maxPending?: number;
  maxInFlight?: number;
  maxMessageBytes?: number;
  maxSubscriptions?: number;
  maxEventListeners?: number;
}

/** The `createClient` a generated TypeScript client exports. */
export type ClientFactory<C extends { receive(message: string): void; close(): void }> = (
  post: (message: string) => void,
  session: string,
  options?: ClientLimits,
) => C;

interface MessageTransport {
  postMessage(message: string): void;
  addEventListener(type: "message", listener: (event: { data: unknown }) => void): void;
  removeEventListener(type: "message", listener: (event: { data: unknown }) => void): void;
}

interface Configuration {
  ziggurat: "runtime";
  v: 1;
  platform: Platform;
  windowId: number;
  version: string;
  locale: string;
  dir: Direction;
  preferences: Preferences;
  services: Record<string, string>;
}

interface Connection {
  readonly runtime: Runtime;
  readonly sessions: Readonly<Record<string, string>>;
  readonly client: RuntimeClient;
  readonly clients: Map<string, { receive(message: string): void; close(): void }>;
}

const hello = '{"ziggurat":"hello","v":1}';
const sessionPrefix = '{"v":1,"session":"';
const configurationPrefix = '{"ziggurat":"runtime"';
const shared = Symbol.for("ziggurat.runtime");

/** The transport the host gives its pages, or undefined in a regular browser. */
function transport(): MessageTransport | undefined {
  const chrome = (globalThis as { chrome?: { webview?: MessageTransport } }).chrome;
  return chrome?.webview && typeof chrome.webview.postMessage === "function" ? chrome.webview : undefined;
}

/** Reports a listener's error without ending delivery to the others. */
const report = (error: unknown) =>
  setTimeout(() => {
    throw error;
  });

/** Whether the page runs in a Ziggurat window rather than a browser tab. */
export function isZiggurat(): boolean {
  return transport() !== undefined;
}

type State = { promise?: Promise<Connection>; connection?: Connection };

// Copies of this package bundled into one page share one connection.
function state(): State {
  const holder = globalThis as unknown as Record<symbol, State | undefined>;
  return (holder[shared] ??= {});
}

/**
 * Connects the page to its host, once per document; later calls return the
 * same connection. Rejects at once outside a Ziggurat window. The host must
 * run the page runtime for this page, or the promise waits for it.
 */
export function connect(): Promise<Runtime> {
  return open().then((connection) => connection.runtime);
}

function open(): Promise<Connection> {
  const current = state();
  if (current.promise) return current.promise;
  const webview = transport();
  if (!webview) return Promise.reject(new Error("ziggurat: no runtime; the page is not in a Ziggurat window"));
  current.promise = new Promise<Connection>((resolve, reject) => {
    let connection: Connection | undefined;
    const listener = (event: { data: unknown }) => {
      const text = event.data;
      if (typeof text !== "string") return;
      if (text.startsWith(sessionPrefix)) {
        const client = connection?.clients.get(text.slice(sessionPrefix.length, sessionPrefix.length + 32));
        if (!client) return;
        try {
          client.receive(text);
        } catch (error) {
          report(error);
        }
        return;
      }
      if (connection || !text.startsWith(configurationPrefix)) return;
      let configuration: Configuration;
      try {
        configuration = JSON.parse(text) as Configuration;
        if (configuration.v !== 1 || typeof configuration.services?.runtime !== "string") throw new Error("ziggurat: unsupported runtime configuration");
      } catch (error) {
        webview.removeEventListener("message", listener);
        reject(error);
        return;
      }
      connection = establish(webview, configuration);
      current.connection = connection;
      resolve(connection);
    };
    webview.addEventListener("message", listener);
    try {
      webview.postMessage(hello);
    } catch (error) {
      webview.removeEventListener("message", listener);
      current.promise = undefined;
      reject(error);
    }
  });
  return current.promise;
}

function establish(webview: MessageTransport, configuration: Configuration): Connection {
  const post = (message: string) => webview.postMessage(message);
  const clients = new Map<string, { receive(message: string): void; close(): void }>();
  const client = createRuntimeClient(post, configuration.services.runtime);
  clients.set(configuration.services.runtime, client);
  const runtime = {
    platform: configuration.platform,
    windowId: configuration.windowId,
    version: configuration.version,
    locale: configuration.locale,
    dir: configuration.dir === "rtl" ? "rtl" : "ltr",
    preferences: Object.freeze({ ...configuration.preferences }),
    services: Object.freeze(Object.keys(configuration.services)),
  } as { -readonly [K in keyof Runtime]: Runtime[K] };
  const connection: Connection = { runtime, client, clients, sessions: Object.freeze({ ...configuration.services }) };
  apply(runtime);
  // The runtime's own listeners come first, so that page listeners already
  // read the new values from runtime().
  client.on("locale", ({ locale, dir }) => {
    runtime.locale = locale;
    runtime.dir = dir;
  });
  client.on("preferences", (preferences) => {
    runtime.preferences = Object.freeze({ ...preferences });
    apply(runtime);
  });
  return connection;
}

/** Mirrors the preferences into CSS variables of `:root`. */
function apply(runtime: Runtime): void {
  const root = (globalThis as { document?: { documentElement?: { style?: { setProperty(name: string, value: string): void; removeProperty(name: string): void } } } }).document?.documentElement;
  const style = root?.style;
  if (!style) return;
  if (runtime.preferences.accent) style.setProperty("--ziggurat-accent", runtime.preferences.accent);
  else style.removeProperty("--ziggurat-accent");
  style.setProperty("--ziggurat-text-scale", String(runtime.preferences.textScale));
}

/** The connected runtime. Throws before {@link connect} has resolved. */
export function runtime(): Runtime {
  const connection = state().connection;
  if (!connection) throw new Error("ziggurat: not connected; await connect() first");
  return connection.runtime;
}

/** The app's language; throws before {@link connect} has resolved. */
export function locale(): string {
  return runtime().locale;
}

/** The direction of the app's language; throws before {@link connect}. */
export function direction(): Direction {
  return runtime().dir;
}

/** The desktop's preferences; throws before {@link connect}. */
export function preferences(): Preferences {
  return runtime().preferences;
}

/**
 * Connects a generated client to the host's service `name`, such as
 * "plugin:sqlite": plugins' packages call this with the `createClient` of
 * their generated client. One client serves each service per document.
 */
export async function service<C extends { receive(message: string): void; close(): void }>(
  name: string,
  create: ClientFactory<C>,
  limits?: ClientLimits,
): Promise<C> {
  const connection = await open();
  const session = connection.sessions[name];
  if (typeof session !== "string") {
    throw new Error(`ziggurat: the host offers no service "${name}"; register its plugin with Host.use`);
  }
  const existing = connection.clients.get(session);
  if (existing) return existing as C;
  const webview = transport()!;
  const client = create((message) => webview.postMessage(message), session, limits);
  connection.clients.set(session, client);
  return client;
}

/** Listens to a runtime event from now on; returns a function that stops. */
function listen<K extends keyof Events>(name: K, listener: (value: Events[K]) => void): () => void {
  let off: (() => void) | undefined;
  let stopped = false;
  open().then(
    (connection) => {
      if (!stopped) off = connection.client.on(name, listener);
    },
    () => {},
  );
  return () => {
    stopped = true;
    off?.();
    off = undefined;
  };
}

/** Hears changes of the app's language. Returns a function that stops. */
export function onLocaleChange(listener: (locale: string, dir: Direction) => void): () => void {
  return listen("locale", (change) => listener(change.locale, change.dir));
}

/** Hears changes of the desktop's preferences. Returns a function that stops. */
export function onPreferences(listener: (preferences: Preferences) => void): () => void {
  return listen("preferences", () => listener(runtime().preferences));
}

/** Hears files dropped on the window. Returns a function that stops. */
export function onFileDrop(listener: (drop: FileDrop) => void): () => void {
  return listen("fileDrop", listener);
}

/** Hears the state of the window's document. Returns a function that stops. */
export function onDocumentState(listener: (state: DocumentState) => void): () => void {
  return listen("documentState", listener);
}

/**
 * Hears the window's document being read from its file again: reverted, or
 * changed by another app while it had no unsaved changes.
 */
export function onDocumentReload(listener: () => void): () => void {
  return listen("documentReload", () => listener());
}

const control = <R>(call: (client: RuntimeClient) => { result: Promise<R> }) => async (): Promise<R> =>
  call((await open()).client).result;

/** The window hosting the page. */
export const currentWindow: WindowControls = {
  minimize: control((client) => client.minimize()),
  maximize: control((client) => client.maximize()),
  unmaximize: control((client) => client.unmaximize()),
  toggleMaximize: control((client) => client.toggleMaximize()),
  isMaximized: control((client) => client.isMaximized()),
  toggleFullScreen: control((client) => client.toggleFullScreen()),
  close: control((client) => client.closeWindow()),
  setTitle: async (title: string) => (await open()).client.setTitle({ title }).result,
};

/** Whether an error came from the host's reply rather than the page. */
export function isRemoteError(error: unknown): error is Error & { code: string } {
  return error instanceof Error && error.name === "RemoteError";
}
