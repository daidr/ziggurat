/**
 * The WebSocket plugin's page half: a `WebSocket` whose connection the
 * Ziggurat host makes, with the API of the browser's. Unlike the browser's,
 * it may send any header with the opening handshake, such as Authorization,
 * Cookie or Origin, and the page's Content Security Policy does not apply.
 * The host registers the plugin with `Host.use`.
 *
 * ```ts
 * import { WebSocket } from "@ziggurat/plugin-websocket";
 *
 * const ws = new WebSocket("wss://example.com/live", ["v1"], {
 *   headers: { authorization: `Bearer ${token}` },
 * });
 * ws.onopen = () => ws.send("hello");
 * ws.onmessage = (e) => console.log(e.data);
 * ws.onclose = (e) => console.log(e.code, e.reason, e.wasClean);
 * ```
 *
 * @module
 */
import { isRemoteError, service } from "@ziggurat/runtime";
import { createClient, type Client } from "./generated/websocket";

/** Must match the Zig service's limits. */
export const limits = { maxPending: 32, maxInFlight: 16, maxMessageBytes: 64 * 1024 };

/** Message bytes in one piece sent to the host. */
const PIECE_BYTES = 32 * 1024;
const ids = Symbol.for("ziggurat.plugin-websocket.ids");

/** Options of a {@link WebSocket}, beyond the browser's. */
export interface WebSocketOptions {
  /** Headers of the opening handshake, e.g. Authorization or Origin. */
  headers?: HeadersInit;
}

type HostEvent = {
  kind: "open" | "text" | "binary" | "close";
  protocol: string | null;
  data: string | null;
  last: boolean;
  code: number;
  reason: string | null;
  clean: boolean;
  error: string | null;
};

/** What the page sends, in order: a message's bytes, or the close. */
type Outgoing =
  | { kind: "text" | "binary"; bytes: Uint8Array | Promise<Uint8Array | null>; size: number }
  | { kind: "close"; code: number; reason: string };

export interface WebSocketEventMap {
  open: Event;
  message: MessageEvent;
  error: Event;
  close: CloseEvent;
}

type Handler<E> = ((this: WebSocket, ev: E) => unknown) | null;

const CONNECTING = 0;
const OPEN = 1;
const CLOSING = 2;
const CLOSED = 3;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

async function client(): Promise<Client> {
  try {
    return await service("plugin:websocket", createClient, limits);
  } catch (error) {
    if (error instanceof Error && error.message.includes("Host.use")) {
      throw new Error("@ziggurat/plugin-websocket: the host does not use the WebSocket plugin; register it with Host.use");
    }
    throw error;
  }
}

/**
 * A WebSocket connection made by the host, with the API of the browser's
 * `WebSocket`. The third argument sets headers of the opening handshake.
 * Messages are sent in order; `bufferedAmount` counts the bytes the host has
 * not taken yet, and received messages wait in the host while the page is
 * behind. The connection closes (1001, going away) when its page navigates
 * away. No extensions are negotiated.
 */
export class WebSocket extends EventTarget {
  static readonly CONNECTING = CONNECTING;
  static readonly OPEN = OPEN;
  static readonly CLOSING = CLOSING;
  static readonly CLOSED = CLOSED;
  declare readonly CONNECTING: 0;
  declare readonly OPEN: 1;
  declare readonly CLOSING: 2;
  declare readonly CLOSED: 3;

  /** The URL of the connection, with a ws: or wss: scheme. */
  readonly url: string;
  /** How binary messages arrive: as a `Blob`, or an `ArrayBuffer`. */
  binaryType: BinaryType = "blob";

  #id: number;
  #state: number = CONNECTING;
  #protocol = "";
  #buffered = 0;
  #queue: Outgoing[] = [];
  #sending = false;
  #host: Client | undefined;
  #cancel: (() => void) | undefined;
  /** The message arriving in pieces. */
  #pieces: Uint8Array[] = [];
  /** Why the connection failed, when the page failed it. */
  #failed: string | undefined;
  #handlers = new Map<string, { fn: Handler<any> }>();

  constructor(url: string | URL, protocols: string | string[] = [], options: WebSocketOptions = {}) {
    super();
    const base = typeof location !== "undefined" ? location.href : undefined;
    let u: URL;
    try {
      u = new URL(url, base);
    } catch {
      throw new DOMException(`Invalid URL: ${url}`, "SyntaxError");
    }
    if (u.protocol === "http:") u.protocol = "ws:";
    else if (u.protocol === "https:") u.protocol = "wss:";
    if (u.protocol !== "ws:" && u.protocol !== "wss:") {
      throw new DOMException(`The URL's scheme must be ws or wss, not ${u.protocol.slice(0, -1)}`, "SyntaxError");
    }
    if (u.hash) throw new DOMException("The URL contains a fragment", "SyntaxError");
    const list = typeof protocols === "string" ? [protocols] : [...protocols];
    if (new Set(list).size !== list.length) {
      throw new DOMException("The subprotocols contain duplicates", "SyntaxError");
    }
    for (const protocol of list) {
      if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(protocol)) {
        throw new DOMException(`Invalid subprotocol: ${protocol}`, "SyntaxError");
      }
    }
    this.url = u.href;
    const counter = globalThis as unknown as Record<symbol, number | undefined>;
    this.#id = counter[ids] = ((counter[ids] ?? 0) + 1) >>> 0;
    const headers = [...new Headers(options.headers)].map(([name, value]) => ({ name, value }));
    void this.#run(list, headers);
  }

  /** The state of the connection: CONNECTING, OPEN, CLOSING or CLOSED. */
  get readyState(): number {
    return this.#state;
  }

  /** The subprotocol the server chose, once open. */
  get protocol(): string {
    return this.#protocol;
  }

  /** The extensions in use: none. */
  get extensions(): string {
    return "";
  }

  /** Bytes sent with `send` that the host has not taken yet. */
  get bufferedAmount(): number {
    return this.#buffered;
  }

  get onopen(): Handler<Event> {
    return this.#handler("open");
  }
  set onopen(fn: Handler<Event>) {
    this.#setHandler("open", fn);
  }
  get onmessage(): Handler<MessageEvent> {
    return this.#handler("message");
  }
  set onmessage(fn: Handler<MessageEvent>) {
    this.#setHandler("message", fn);
  }
  get onerror(): Handler<Event> {
    return this.#handler("error");
  }
  set onerror(fn: Handler<Event>) {
    this.#setHandler("error", fn);
  }
  get onclose(): Handler<CloseEvent> {
    return this.#handler("close");
  }
  set onclose(fn: Handler<CloseEvent>) {
    this.#setHandler("close", fn);
  }

  /** Sends a message: text, or binary data. Throws while connecting. */
  send(data: string | ArrayBufferLike | ArrayBufferView | Blob): void {
    if (this.#state === CONNECTING) throw new DOMException("The connection is not open yet", "InvalidStateError");
    let message: Outgoing;
    if (typeof data === "string") {
      const bytes = encoder.encode(data);
      message = { kind: "text", bytes, size: bytes.length };
    } else if (typeof Blob !== "undefined" && data instanceof Blob) {
      message = {
        kind: "binary",
        bytes: data.arrayBuffer().then(
          (buffer) => new Uint8Array(buffer),
          () => null,
        ),
        size: data.size,
      };
    } else {
      const bytes = ArrayBuffer.isView(data)
        ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice()
        : new Uint8Array(data as ArrayBufferLike).slice();
      message = { kind: "binary", bytes, size: bytes.length };
    }
    this.#buffered += message.size;
    // Discarded once closing, as browsers do; bufferedAmount keeps them.
    if (this.#state !== OPEN) return;
    this.#queue.push(message);
    void this.#pump();
  }

  /**
   * Closes the connection with a code (1000, or 3000 to 4999) and a reason
   * of at most 123 bytes, after the messages already sent.
   */
  close(code?: number, reason?: string): void {
    if (code !== undefined && code !== 1000 && !(code >= 3000 && code <= 4999)) {
      throw new DOMException(`Invalid close code ${code}`, "InvalidAccessError");
    }
    const why = reason ?? "";
    if (encoder.encode(why).length > 123) throw new DOMException("The close reason is over 123 bytes", "SyntaxError");
    if (this.#state === CLOSING || this.#state === CLOSED) return;
    if (this.#state === CONNECTING) {
      this.#state = CLOSING;
      this.#failed = "closed before the connection was established";
      // Stops the handshake; the host ends the connection.
      this.#cancel?.();
      setTimeout(() => this.#finish(1006, "", false, this.#failed));
      return;
    }
    this.#state = CLOSING;
    this.#queue.push({ kind: "close", code: code ?? 1000, reason: why });
    void this.#pump();
  }

  async #run(protocols: string[], headers: { name: string; value: string }[]): Promise<void> {
    let call: ReturnType<Client["connect"]>;
    try {
      this.#host = await client();
      if (this.#state !== CONNECTING) return;
      call = this.#host.connect({ id: this.#id, url: this.url, protocols, headers });
    } catch (error) {
      this.#finish(1006, "", false, failure(error));
      return;
    }
    this.#cancel = () => call.cancel();
    try {
      for await (const event of call as AsyncIterable<HostEvent>) this.#receive(event);
      await call.result;
      this.#finish(1006, "", false, this.#failed ?? "connection lost");
    } catch (error) {
      this.#finish(1006, "", false, this.#failed ?? failure(error));
    }
  }

  /** Sends the queued messages one piece at a time, in order. */
  async #pump(): Promise<void> {
    if (this.#sending) return;
    this.#sending = true;
    try {
      while (this.#queue.length > 0 && this.#state !== CLOSED) {
        const message = this.#queue.shift()!;
        const host = this.#host!;
        if (message.kind === "close") {
          await host.send({ id: this.#id, kind: "close", data: null, last: true, code: message.code, reason: message.reason }).result.catch(() => {});
          continue;
        }
        const bytes = await message.bytes;
        try {
          // A Blob the page could not read sends nothing.
          if (bytes) {
            let offset = 0;
            do {
              const end = Math.min(bytes.length, offset + PIECE_BYTES);
              await host.send({ id: this.#id, kind: message.kind, data: toBase64(bytes.subarray(offset, end)), last: end === bytes.length, code: 0, reason: null }).result;
              offset = end;
            } while (offset < bytes.length);
          }
        } catch {
          // The connection is closing; its close event reports why.
        } finally {
          this.#buffered -= message.size;
        }
      }
    } finally {
      this.#sending = false;
    }
  }

  #receive(event: HostEvent): void {
    switch (event.kind) {
      case "open":
        if (this.#state !== CONNECTING) return;
        this.#state = OPEN;
        this.#protocol = event.protocol ?? "";
        this.dispatchEvent(new Event("open"));
        return;
      case "text":
      case "binary": {
        this.#pieces.push(fromBase64(event.data ?? ""));
        if (!event.last) return;
        const bytes = concat(this.#pieces);
        this.#pieces = [];
        if (this.#state !== OPEN) return;
        const data =
          event.kind === "text"
            ? decoder.decode(bytes)
            : this.binaryType === "arraybuffer"
              ? bytes.buffer
              : new Blob([bytes as Uint8Array<ArrayBuffer>]);
        this.dispatchEvent(new MessageEvent("message", { data, origin: new URL(this.url).origin }));
        return;
      }
      case "close":
        this.#finish(event.code || 1005, event.reason ?? "", event.clean, event.error ?? undefined);
    }
  }

  #finish(code: number, reason: string, wasClean: boolean, error?: string): void {
    if (this.#state === CLOSED) return;
    this.#state = CLOSED;
    this.#queue = [];
    if (error) {
      console.error(`WebSocket connection to '${this.url}' failed: ${error}`);
      this.dispatchEvent(new Event("error"));
    }
    this.dispatchEvent(closeEvent(code, reason, wasClean));
  }

  #handler(type: string): Handler<any> {
    return this.#handlers.get(type)?.fn ?? null;
  }

  // An event handler is a listener added when it is first set, which calls
  // whatever handler is set when the event fires.
  #setHandler(type: string, fn: Handler<any>): void {
    let entry = this.#handlers.get(type);
    if (!entry) {
      const e = (entry = { fn: null as Handler<any> });
      this.#handlers.set(type, e);
      this.addEventListener(type, (ev) => e.fn?.call(this, ev));
    }
    entry.fn = typeof fn === "function" ? fn : null;
  }
}

for (const [name, value] of Object.entries({ CONNECTING, OPEN, CLOSING, CLOSED })) {
  Object.defineProperty(WebSocket.prototype, name, { value, enumerable: true });
}

export interface WebSocket {
  addEventListener<K extends keyof WebSocketEventMap>(
    type: K,
    listener: (this: WebSocket, ev: WebSocketEventMap[K]) => unknown,
    options?: boolean | AddEventListenerOptions,
  ): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: boolean | AddEventListenerOptions): void;
  removeEventListener<K extends keyof WebSocketEventMap>(
    type: K,
    listener: (this: WebSocket, ev: WebSocketEventMap[K]) => unknown,
    options?: boolean | EventListenerOptions,
  ): void;
  removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: boolean | EventListenerOptions): void;
}

export default WebSocket;

function closeEvent(code: number, reason: string, wasClean: boolean): CloseEvent {
  if (typeof CloseEvent !== "undefined") return new CloseEvent("close", { code, reason, wasClean });
  return Object.assign(new Event("close"), { code, reason, wasClean }) as CloseEvent;
}

/** Why the connection failed. */
function failure(error: unknown): string {
  if (isRemoteError(error)) return error.message;
  return error instanceof Error ? error.message : String(error);
}

function concat(pieces: Uint8Array[]): Uint8Array {
  if (pieces.length === 1) return pieces[0]!;
  const bytes = new Uint8Array(pieces.reduce((sum, piece) => sum + piece.length, 0));
  let offset = 0;
  for (const piece of pieces) {
    bytes.set(piece, offset);
    offset += piece.length;
  }
  return bytes;
}

function toBase64(bytes: Uint8Array): string {
  const native = (bytes as { toBase64?: () => string }).toBase64;
  if (native) return native.call(bytes);
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000) as unknown as number[]);
  }
  return btoa(s);
}

function fromBase64(s: string): Uint8Array {
  const native = (Uint8Array as { fromBase64?: (s: string) => Uint8Array }).fromBase64;
  if (native) return native(s);
  const bin = atob(s);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
