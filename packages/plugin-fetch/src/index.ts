/**
 * The fetch plugin's page half: a `fetch` that makes HTTP requests from the
 * Ziggurat host, free of CORS and of the WebView's header rules. It takes
 * the standard options and returns a standard `Response`, whose body streams
 * as the host reads it. The host registers the plugin with `Host.use`.
 *
 * ```ts
 * import { fetch } from "@ziggurat/plugin-fetch";
 *
 * const res = await fetch("https://api.example.com/items", {
 *   headers: { authorization: `Bearer ${token}` },
 * });
 * const items = await res.json();
 * ```
 *
 * URLs that are not http or https, such as the app's own pages, `data:` and
 * `blob:` URLs, go to the WebView's `fetch`.
 *
 * @module
 */
import { isRemoteError, service } from "@ziggurat/runtime";
import { createClient, type Client } from "./generated/fetch";

/** Must match the Zig service's limits. */
export const limits = { maxPending: 32, maxInFlight: 32, maxMessageBytes: 64 * 1024 };

/** Bodies up to this size travel in the call; larger ones as upload pieces. */
const INLINE_BYTES = 32 * 1024;
const PIECE_BYTES = 36 * 1024;
const uploads = Symbol.for("ziggurat.plugin-fetch.uploads");

/** Statuses whose responses have no body. */
const NULL_BODY = new Set([101, 103, 204, 205, 304]);

/** Methods whose names are normalized to upper case, as `fetch` does. */
const NORMALIZED = new Set(["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"]);

type Part = { head: { status: number; statusText: string; url: string; redirected: boolean; headers: ReadonlyArray<{ name: string; value: string }> } | null; chunk: string | null };

async function client(): Promise<Client> {
  try {
    return await service("plugin:fetch", createClient, limits);
  } catch (error) {
    if (error instanceof Error && error.message.includes("Host.use")) {
      throw new Error("@ziggurat/plugin-fetch: the host does not use the fetch plugin; register it with Host.use");
    }
    throw error;
  }
}

/**
 * Makes an HTTP request from the host, with the options and result of the
 * standard `fetch`. `mode`, `credentials`, `cache` and the like have no
 * meaning there and are ignored; no cookies are kept. Response headers are
 * all there but `Set-Cookie`.
 */
export async function fetch(input: RequestInfo | URL, init: RequestInit = {}): Promise<Response> {
  const req = typeof Request !== "undefined" && input instanceof Request ? input : null;
  const base = typeof location !== "undefined" ? location.href : undefined;
  const url = new URL(req ? req.url : input instanceof URL ? input.href : String(input), base);
  if (url.protocol !== "http:" && url.protocol !== "https:") return globalThis.fetch(input, init);

  const signal = init.signal ?? req?.signal ?? null;
  signal?.throwIfAborted();
  let method = init.method ?? req?.method ?? "GET";
  if (NORMALIZED.has(method.toUpperCase())) method = method.toUpperCase();
  // Plain Headers keep the names a Request would drop, such as Origin.
  const headers = new Headers(init.headers ?? req?.headers);
  let body: Uint8Array | null = null;
  if (init.body != null) {
    const r = new Response(init.body);
    const type = r.headers.get("content-type");
    if (type && !headers.has("content-type")) headers.set("content-type", type);
    body = new Uint8Array(await r.arrayBuffer());
  } else if (init.body === undefined && req?.body) {
    body = new Uint8Array(await req.arrayBuffer());
  }
  if (body && (method === "GET" || method === "HEAD")) {
    throw new TypeError(`fetch: a ${method} request cannot have a body`);
  }

  const host = await client();
  let upload: number | null = null;
  if (body && body.length > INLINE_BYTES) {
    const counter = globalThis as unknown as Record<symbol, number | undefined>;
    upload = counter[uploads] = ((counter[uploads] ?? 0) + 1) >>> 0;
    for (let offset = 0; offset < body.length; offset += PIECE_BYTES) {
      signal?.throwIfAborted();
      try {
        await host.upload({ upload, data: toBase64(body.subarray(offset, offset + PIECE_BYTES)) }).result;
      } catch (error) {
        throw failure(error);
      }
    }
  }
  const call = host.fetch({
    url: url.href,
    method,
    headers: [...headers].map(([name, value]) => ({ name, value })),
    body: body && upload === null ? toBase64(body) : null,
    upload,
    redirect: init.redirect ?? req?.redirect ?? "follow",
  });
  // The result's rejection is taken where it matters.
  const failed = call.result.then(
    () => null,
    (error: unknown) => failure(error),
  );
  const parts = call[Symbol.asyncIterator]() as AsyncIterator<Part>;

  let stream: ReadableStreamDefaultController<Uint8Array> | undefined;
  let rejectHead: ((reason: unknown) => void) | undefined;
  let aborted = false;
  const onAbort = () => {
    aborted = true;
    call.cancel();
    try {
      stream?.error(signal!.reason);
    } catch {}
    rejectHead?.(signal!.reason);
  };
  signal?.addEventListener("abort", onAbort, { once: true });
  const cleanup = () => signal?.removeEventListener("abort", onAbort);

  let head: NonNullable<Part["head"]>;
  try {
    const first = await new Promise<IteratorResult<Part>>((resolve, reject) => {
      rejectHead = reject;
      parts.next().then(resolve, async () => reject(aborted ? signal!.reason : await failed));
    });
    rejectHead = undefined;
    if (first.done || !first.value.head) throw (await failed) ?? new TypeError("fetch failed: no response");
    head = first.value.head;
  } catch (error) {
    cleanup();
    call.cancel();
    throw error;
  }

  const status = head.status;
  const nullBody = NULL_BODY.has(status) || method === "HEAD";
  const readable = nullBody
    ? null
    : new ReadableStream<Uint8Array>(
        {
          start(controller) {
            stream = controller;
          },
          async pull(controller) {
            let next: IteratorResult<Part>;
            try {
              next = await parts.next();
            } catch {
              if (aborted) return;
              cleanup();
              controller.error((await failed) ?? new TypeError("fetch failed"));
              return;
            }
            if (aborted) return;
            if (!next.done) {
              if (next.value.chunk) controller.enqueue(fromBase64(next.value.chunk));
              return;
            }
            cleanup();
            const error = await failed;
            if (error) controller.error(error);
            else controller.close();
          },
          cancel() {
            cleanup();
            call.cancel();
          },
        },
        { highWaterMark: 0 },
      );
  if (nullBody) {
    call.cancel();
    cleanup();
  }
  // Response takes statuses from 200 to 599 only.
  const valid = status >= 200 && status <= 599;
  const res = new Response(readable, {
    status: valid ? status : 200,
    statusText: head.statusText,
    headers: head.headers.map(({ name, value }) => [name, value] as [string, string]),
  });
  const own = (name: string, value: unknown) => Object.defineProperty(res, name, { value, enumerable: true });
  own("url", head.url || url.href);
  own("redirected", head.redirected);
  if (!valid) own("status", status);
  // Reading an aborted body rejects with the signal's reason, as fetch's
  // own does; a WebView may instead report its stream error as its own.
  if (readable && signal) {
    for (const name of ["arrayBuffer", "blob", "bytes", "formData", "json", "text"] as const) {
      const read = (res as unknown as Record<string, unknown>)[name];
      if (typeof read !== "function") continue;
      own(name, (...args: unknown[]) =>
        (read.apply(res, args) as Promise<unknown>).catch((error: unknown) => {
          throw aborted ? signal.reason : error;
        }),
      );
    }
  }
  return res;
}

export default fetch;

/** The error a failed request rejects with. */
function failure(error: unknown): Error {
  if (isRemoteError(error)) return new TypeError(`fetch failed: ${error.message}`, { cause: error });
  return error instanceof Error ? error : new TypeError(String(error));
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
