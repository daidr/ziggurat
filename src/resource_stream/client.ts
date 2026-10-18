/** Explicit IPC byte-stream adapter. It does not replace fetch or grant origin
 * access. The supplied generated call retains its normal session/ACK rules. */
export type ResourceHead = {
  readonly status: number;
  readonly mime: string;
  readonly headers: readonly { readonly name: string; readonly value: string }[];
  readonly length: number | null;
};
export type ResourceFrame = {
  head: ResourceHead | null;
  body: { base64: string; bytes: number } | null;
};
export type ResourceSummary = { bytes: number; chunks: number };
// Generated schemas may mark fields with Zig defaults optional. All input is
// validated below, before publishing the fully specified public head/body.
export type ResourceCall = AsyncIterable<unknown> & {
  result: Promise<unknown>;
  cancel(): void;
};
export type ResourceOptions = {
  method?: "get" | "head";
  maxChunkBytes?: number;
  maxTotalBytes?: number;
  maxChunks?: number;
  maxHeaderBytes?: number;
};
export class ResourceStreamError extends Error {
  constructor(readonly code: string) { super(code); this.name = "ResourceStreamError"; }
}
function fail(code: string): never { throw new ResourceStreamError(code); }
const integer = (value: unknown, minimum: number, maximum: number): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= minimum && value <= maximum;
function asciiValue(text: unknown, max: number): text is string {
  if (typeof text !== "string" || text.length > max) return false;
  for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) < 32 || text.charCodeAt(i) > 126) return false;
  return true;
}
const token = (text: unknown): text is string => typeof text === "string" && text.length > 0 && text.length <= 64 &&
  /^[A-Za-z0-9!#$%&'*+.^_`|~-]+$/.test(text);
const reserved = new Set(["content-type", "content-length", "transfer-encoding", "connection", "keep-alive", "te", "trailer", "upgrade", "proxy-authenticate", "proxy-authorization"]);

function validateHead(value: ResourceHead, total: number, headerBytes: number): ResourceHead {
  if (!value || !integer(value.status, 200, 599) || !asciiValue(value.mime, 127) || value.mime.length === 0 ||
      (value.length !== null && !integer(value.length, 0, total)) || !Array.isArray(value.headers) || value.headers.length > 16) fail("InvalidHead");
  if ([204, 205, 304].includes(value.status) && value.length !== null && value.length !== 0) fail("UnexpectedBody");
  let bytes = 0;
  const names = new Set<string>();
  for (const header of value.headers) {
    if (!header || !token(header.name) || !asciiValue(header.value, 2048)) fail("InvalidHeader");
    const name = header.name.toLowerCase();
    if (names.has(name) || reserved.has(name)) fail("InvalidHeader");
    names.add(name);
    bytes += header.name.length + header.value.length + 4;
    if (bytes > headerBytes) fail("HeaderBudgetExceeded");
  }
  return Object.freeze({ status: value.status, mime: value.mime, length: value.length,
    headers: Object.freeze(value.headers.map(header => Object.freeze({ name: header.name, value: header.value }))) });
}
function digit(code: number): number {
  if (code >= 65 && code <= 90) return code - 65;
  if (code >= 97 && code <= 122) return code - 71;
  if (code >= 48 && code <= 57) return code + 4;
  if (code === 43) return 62;
  if (code === 47) return 63;
  return fail("InvalidBase64");
}
/** Canonical base64 only, including zero unused padding bits. At most one
 * decoded allocation; no temporary atob string or unbounded output buffer. */
export function decodeChunk(text: string, bytes: number, maximum = 16 * 1024): Uint8Array {
  if (!integer(maximum, 1, 16 * 1024) || !integer(bytes, 1, maximum) || typeof text !== "string" || text.length !== 4 * Math.ceil(bytes / 3)) fail("InvalidChunk");
  const output = new Uint8Array(bytes);
  for (let source = 0, target = 0; source < text.length; source += 4) {
    const a = digit(text.charCodeAt(source)), b = digit(text.charCodeAt(source + 1));
    const count = Math.min(3, bytes - target);
    const c = count > 1 ? digit(text.charCodeAt(source + 2)) : 0;
    const d = count > 2 ? digit(text.charCodeAt(source + 3)) : 0;
    if ((count === 1 && (text[source + 2] !== "=" || text[source + 3] !== "=" || (b & 15) !== 0)) ||
        (count === 2 && (text[source + 3] !== "=" || (c & 3) !== 0))) fail("InvalidBase64");
    output[target++] = (a << 2) | (b >> 4);
    if (count > 1) output[target++] = (b << 4) | (c >> 2);
    if (count > 2) output[target++] = (c << 6) | d;
  }
  return output;
}

export function resourceReadable(call: ResourceCall, options: ResourceOptions = {}) {
  const chunkLimit = options.maxChunkBytes ?? 16 * 1024;
  const totalLimit = options.maxTotalBytes ?? 256 * 1024 * 1024;
  const chunksLimit = options.maxChunks ?? 1_000_000;
  const headerLimit = options.maxHeaderBytes ?? 8192;
  if ((options.method !== undefined && options.method !== "get" && options.method !== "head") ||
      !integer(chunkLimit, 1, 16 * 1024) || !integer(totalLimit, 1, Number.MAX_SAFE_INTEGER) ||
      !integer(chunksLimit, 1, 0xfffffffd) || !integer(headerLimit, 1, 8192)) fail("InvalidLimits");
  const iterator = call[Symbol.asyncIterator]();
  let resolveHead!: (head: ResourceHead) => void, rejectHead!: (error: unknown) => void;
  let resolveDone!: (summary: ResourceSummary) => void, rejectDone!: (error: unknown) => void;
  const head = new Promise<ResourceHead>((resolve, reject) => { resolveHead = resolve; rejectHead = reject; });
  const completion = new Promise<ResourceSummary>((resolve, reject) => { resolveDone = resolve; rejectDone = reject; });
  void head.catch(() => {}); void completion.catch(() => {}); void call.result.catch(() => {});
  let stopped = false, received = 0, chunks = 0;
  let metadata: ResourceHead | undefined, controller: ReadableStreamDefaultController<Uint8Array>;
  const abort = (error: unknown, notify: boolean) => {
    if (stopped) return;
    stopped = true;
    rejectHead(error); rejectDone(error);
    if (notify) controller.error(error);
    try { call.cancel(); } catch { /* Original failure remains authoritative. */ }
    void iterator.return?.().catch(() => {});
  };
  // Exactly one immediate metadata read. Body reads occur only from pull();
  // highWaterMark=0 prevents unread bodies from generating additional ACKs.
  const ready = (async () => {
    const item = await iterator.next();
    if (stopped) return;
    const frame = item.value as ResourceFrame | undefined;
    if (item.done || !frame || frame.head === null || frame.body !== null) fail("MissingHead");
    metadata = validateHead(frame.head, totalLimit, headerLimit);
    resolveHead(metadata);
  })();
  const body = new ReadableStream<Uint8Array>({
    start(value) {
      controller = value;
      void ready.catch(error => abort(error, true));
    },
    async pull(value) {
      try {
        await ready;
        if (stopped) return;
        const item = await iterator.next();
        if (stopped) return;
        if (item.done) {
          const summary = await call.result as ResourceSummary;
          if (stopped) return;
          if (!summary || !integer(summary.bytes, 0, totalLimit) || !integer(summary.chunks, 0, chunksLimit) || summary.bytes !== received || summary.chunks !== chunks ||
              (options.method !== "head" && metadata!.length !== null && metadata!.length !== received)) fail("InvalidSummary");
          stopped = true;
          resolveDone(summary);
          value.close();
          return;
        }
        const source = item.value as ResourceFrame | undefined;
        const frame = source?.body;
        if (!source || source.head !== null || !frame || options.method === "head" || [204, 205, 304].includes(metadata!.status)) return fail("UnexpectedBody");
        if (!integer(frame.bytes, 1, chunkLimit) || frame.bytes > totalLimit - received || chunks === chunksLimit ||
            (metadata!.length !== null && frame.bytes > metadata!.length - received)) fail("BodyBudgetExceeded");
        const bytes = decodeChunk(frame.base64, frame.bytes, chunkLimit);
        received += frame.bytes; chunks++;
        value.enqueue(bytes);
      } catch (error) { abort(error, true); }
    },
    cancel(reason) { abort(reason ?? new ResourceStreamError("Cancelled"), false); },
  }, { highWaterMark: 0 });
  // Transport/navigation failure is terminal even while a consumer pauses and
  // no iterator.next() is outstanding. Successful EOF still waits for drain.
  void call.result.catch(error => abort(error, true));
  return { head, body, completion };
}
