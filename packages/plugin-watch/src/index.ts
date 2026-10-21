/**
 * The watch plugin's page half: changes to the directories and files the app
 * lets pages watch, by the names it gives them. The host registers the
 * plugin with `Host.use` and the roots pages may watch.
 *
 * ```ts
 * import { watch } from "@ziggurat/plugin-watch";
 *
 * const watcher = await watch("project", { recursive: true });
 * for await (const events of watcher) {
 *   for (const event of events) console.log(event.op, event.path);
 * }
 * ```
 *
 * @module
 */
import { isRemoteError, service } from "@ziggurat/runtime";
import { createClient, type Client } from "./generated/watch";

/** Must match the Zig service's limits. */
export const limits = { maxPending: 8, maxInFlight: 4, maxMessageBytes: 64 * 1024 };

/** The kind of a {@link FileEvent}. */
export type FileOp = "create" | "write" | "remove" | "rename";

/**
 * A change in a watched directory or file. Events say what is different
 * once changes stop, not every step that made it so: treat them as hints
 * to read the files again.
 */
export interface FileEvent {
  op: FileOp;
  /** The path relative to what is watched, separated by slashes; "." is what is watched itself. */
  path: string;
  /** Where a rename moved from. */
  oldPath?: string;
  isDir: boolean;
}

/** Options of {@link watch}. */
export interface WatchOptions {
  /** What to watch in the root, a directory or a file, relative to it and separated by slashes: the root itself by default. */
  path?: string;
  /** Watch the directories in the directory too, if the app allows it. */
  recursive?: boolean;
  /** How long changes must stop before they are reported: 50 ms when 0 or omitted, right away when negative. */
  debounceMs?: number;
  /** Stops the watch when aborted. */
  signal?: AbortSignal;
}

/** Why a watch failed or stopped; see {@link WatchError}. */
export type WatchErrorCode = "denied" | "limit" | "not-found" | "unsupported" | "path-encoding" | "io";

/** A watch that failed to start or stopped, with the reason as its code. */
export class WatchError extends Error {
  constructor(
    readonly code: WatchErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "WatchError";
  }
}

/**
 * A running watch: iterate it for the changes, a batch of events each time
 * they stop. The host does not look again until the page has taken a
 * batch, so nothing is lost while the page is busy.
 */
export interface Watcher extends AsyncIterable<FileEvent[]> {
  /** Settles once the watch stopped, rejecting with the error that stopped it. */
  readonly closed: Promise<void>;
  /** Stops the watch. */
  close(): Promise<void>;
}

type Part = {
  ready: boolean;
  events: ReadonlyArray<{ op: FileOp; path: string; oldPath: string | null; isDir: boolean }>;
  more: boolean;
};

const codes: readonly string[] = ["denied", "limit", "not-found", "unsupported", "path-encoding", "io"];

async function client(): Promise<Client> {
  try {
    return await service("plugin:watch", createClient, limits);
  } catch (error) {
    if (error instanceof Error && error.message.includes("Host.use")) {
      throw new Error("@ziggurat/plugin-watch: the host does not use the watch plugin; register it with Host.use");
    }
    throw error;
  }
}

/**
 * Watches the directory or file the app named `root`, or `path` in it, and
 * resolves once everything is watched. What is already there is not
 * reported. When it is removed, renamed or replaced, the last batch has a
 * "remove" of ".", and the iteration ends.
 */
export async function watch(root: string, options: WatchOptions = {}): Promise<Watcher> {
  const debounceMs = options.debounceMs ?? 0;
  if (!Number.isInteger(debounceMs) || debounceMs > 60000 || debounceMs < -0x80000000) {
    throw new TypeError("debounceMs must be an integer up to 60000");
  }
  const path = options.path ?? ".";
  if (typeof path !== "string") throw new TypeError("path must be a string");
  const signal = options.signal;
  signal?.throwIfAborted();
  const host = await client();
  signal?.throwIfAborted();
  const call = host.watch({ root, path, recursive: options.recursive ?? false, debounceMs });
  const parts = call[Symbol.asyncIterator]() as AsyncIterator<Part>;
  // The first error wins: the signal's reason, or the call's.
  let terminal: { error: unknown } | undefined;
  let closing = false;
  let finished = false;
  let iterating = false;
  const record = (error: unknown) => {
    terminal ??= { error };
  };
  const abort = () => {
    if (finished || closing) return;
    record(signal!.reason);
    closing = true;
    call.cancel();
  };
  signal?.addEventListener("abort", abort, { once: true });
  const closed = call.result
    .then(
      () => {
        if (terminal) throw terminal.error;
      },
      (error: unknown) => {
        // Stopping the watch from the page is not a failure.
        if (!closing) record(failure(error));
        if (terminal) throw terminal.error;
      },
    )
    .finally(() => {
      finished = true;
      signal?.removeEventListener("abort", abort);
    });
  void closed.catch(() => {});
  const close = async () => {
    if (!closing && !finished) {
      closing = true;
      call.cancel();
    }
    await closed.catch(() => {});
  };
  try {
    const first = await parts.next().catch(async (error: unknown) => {
      throw await closed.then(
        () => error,
        (reason: unknown) => reason,
      );
    });
    if (first.done) {
      await closed;
      throw new Error("Watch ended before ready");
    }
    if (!first.value.ready) throw new Error("Invalid watch ready response");
    // Aborted while it started; a failure after ready is the iteration's.
    if (closing) {
      await closed;
      throw terminal ? terminal.error : new Error("Watch closed");
    }
  } catch (error) {
    if (!closing && !finished) {
      closing = true;
      call.cancel();
    }
    signal?.removeEventListener("abort", abort);
    throw error;
  }
  return {
    closed,
    close,
    [Symbol.asyncIterator]() {
      if (iterating) throw new Error("A watch supports one iterator");
      iterating = true;
      return (async function* () {
        try {
          let batch: FileEvent[] = [];
          while (!closing) {
            let next: IteratorResult<Part>;
            try {
              next = await parts.next();
            } catch {
              break;
            }
            if (next.done) break;
            for (const event of next.value.events) batch.push(toEvent(event));
            if (next.value.more) continue;
            if (batch.length && !closing) yield batch;
            batch = [];
          }
          await closed;
        } finally {
          await close();
          iterating = false;
        }
      })();
    },
  };
}

function toEvent(event: Part["events"][number]): FileEvent {
  const result: FileEvent = { op: event.op, path: event.path, isDir: event.isDir };
  if (event.oldPath !== null) result.oldPath = event.oldPath;
  return result;
}

/** The error a failed watch rejects with. */
function failure(error: unknown): unknown {
  if (isRemoteError(error)) {
    return codes.includes(error.code) ? new WatchError(error.code as WatchErrorCode, error.message) : new Error("Invalid watch outcome");
  }
  return error;
}
