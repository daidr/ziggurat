/**
 * The SQLite plugin's page half: databases in the directory the host gives
 * the plugin. The host registers the plugin with `Host.use`.
 *
 * ```ts
 * import { open } from "@ziggurat/plugin-sqlite";
 *
 * const db = await open("app.db");
 * await db.execute("CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY, title TEXT, done INTEGER)");
 * const inserted = await db.execute("INSERT INTO tasks(title, done) VALUES (?, ?)", ["Write docs", false]);
 * const { columns, rows } = await db.query("SELECT id, title FROM tasks WHERE done = ?", [false]);
 * await db.transaction([
 *   { sql: "UPDATE tasks SET done = ? WHERE id = ?", params: [true, inserted.lastInsertId] },
 *   { sql: "INSERT INTO tasks(title, done) VALUES (?, ?)", params: ["Ship", false] },
 * ]);
 * await db.close();
 * ```
 *
 * @module
 */
import { isRemoteError, service } from "@ziggurat/runtime";
import { createClient, type Client, type Methods } from "./generated/sqlite";

/** Must match the Zig service's limits. */
export const limits = { maxPending: 32, maxInFlight: 8, maxMessageBytes: 64 * 1024 };

/** SQLite values: integers beyond Number's safe range are returned as bigint. */
export type Value = null | number | bigint | string | Uint8Array;
/** Booleans bind as the integers 0 and 1. */
export type Parameter = Value | boolean;
/** Options of {@link open}. */
export interface OpenOptions {
  /** Open without writing; a missing database is not created. */
  readOnly?: boolean;
}
/** What a statement changed. */
export interface Result {
  changes: number;
  /** The last inserted rowid on this connection, without precision loss. */
  lastInsertId: bigint;
}
/** Ordered columns and cells keep duplicate column names. */
export interface Rows {
  columns: string[];
  rows: Value[][];
}
/** One statement of a {@link Database.transaction}. */
export interface Statement {
  sql: string;
  params?: readonly Parameter[];
}

/** Why an operation failed; see {@link SqliteError}. */
export type SqliteErrorCode = "invalid" | "denied" | "closed" | "limit" | "unsupported" | "sqlite";

/** A failed operation, with the reason as its code. */
export class SqliteError extends Error {
  constructor(
    readonly code: SqliteErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "SqliteError";
  }
}

type WireValue = Methods["execute"]["params"]["params"][number];
type WireResult = Methods["execute"]["result"];

const codes: readonly string[] = ["invalid", "denied", "closed", "limit", "unsupported", "sqlite"];

async function client(): Promise<Client> {
  try {
    return await service("plugin:sqlite", createClient, limits);
  } catch (error) {
    if (error instanceof Error && error.message.includes("Host.use")) {
      throw new Error("@ziggurat/plugin-sqlite: the host does not use the SQLite plugin; register it with Host.use");
    }
    throw error;
  }
}

/** Opens a file name in the plugin's directory, separated by slashes, or a private ":memory:" database. */
export async function open(name: string, options: OpenOptions = {}): Promise<Database> {
  return Database.open(name, options);
}

/** A page-owned connection. It closes when the page navigates or the app quits. */
export class Database {
  private closing?: Promise<void>;
  private closed = false;
  private constructor(
    private readonly host: Client,
    private readonly id: number,
  ) {}

  static async open(name: string, options: OpenOptions = {}): Promise<Database> {
    if (typeof name !== "string") throw new TypeError("sqlite: name must be a string");
    const host = await client();
    const id = await settle(host.open({ name, readOnly: options.readOnly ?? false }).result);
    return new Database(host, id);
  }

  /** Executes exactly one statement. Use placeholders, never interpolate values. */
  async execute(sql: string, params: readonly Parameter[] = []): Promise<Result> {
    this.assertOpen();
    return result(await settle(this.host.execute({ connection: this.id, sql, params: params.map(encode) }).result));
  }

  /** Queries one statement, including RETURNING; select a bounded page for large results. */
  async query(sql: string, params: readonly Parameter[] = []): Promise<Rows> {
    this.assertOpen();
    const call = this.host.query({ connection: this.id, sql, params: params.map(encode) });
    const rows: Value[][] = [];
    let columns: string[] = [];
    try {
      // Rows larger than one message arrive in several parts.
      for await (const part of call) {
        if (part.columns) columns = [...part.columns];
        for (const row of part.rows) rows.push(row.map(decode));
      }
    } catch {
      // The call's result carries the failure.
    }
    await settle(call.result);
    return { columns, rows };
  }

  /** Runs an atomic BEGIN IMMEDIATE batch. A failure rolls back every statement. */
  async transaction(statements: readonly Statement[]): Promise<Result[]> {
    this.assertOpen();
    const batch = statements.map((statement) => ({ sql: statement.sql, params: (statement.params ?? []).map(encode) }));
    return (await settle(this.host.transaction({ connection: this.id, statements: batch }).result)).map(result);
  }

  /** Closes this connection. Concurrent and repeated closes share the same call. */
  close(): Promise<void> {
    if (this.closed) return Promise.resolve();
    if (!this.closing) {
      this.closing = settle(this.host.closeDatabase({ connection: this.id }).result).then(
        () => {
          this.closed = true;
        },
        (error: unknown) => {
          this.closing = undefined;
          throw error;
        },
      );
    }
    return this.closing;
  }

  private assertOpen(): void {
    if (this.closed || this.closing) throw new SqliteError("closed", "sqlite: database is closed");
  }
}

/** The call's value, or its failure as a {@link SqliteError}. */
async function settle<T>(promise: Promise<T>): Promise<T> {
  try {
    return await promise;
  } catch (error) {
    if (isRemoteError(error)) {
      throw codes.includes(error.code) ? new SqliteError(error.code as SqliteErrorCode, error.message) : new Error("Invalid sqlite outcome");
    }
    throw error;
  }
}

function result(value: WireResult): Result {
  return { changes: value.changes, lastInsertId: BigInt(value.lastInsertId) };
}

const empty = { integer: null, real: null, special: null, text: null, blob: null } as const;

function encode(value: Parameter): WireValue {
  if (value === null) return { type: "null", ...empty };
  if (typeof value === "boolean") return { type: "integer", ...empty, integer: value ? "1" : "0" };
  if (typeof value === "bigint") {
    if (value < -(1n << 63n) || value >= 1n << 63n) throw new RangeError("sqlite: integer exceeds signed 64-bit range");
    return { type: "integer", ...empty, integer: String(value) };
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("sqlite: number must be finite");
    if (Number.isInteger(value)) {
      if (!Number.isSafeInteger(value)) throw new RangeError("sqlite: use bigint for integers outside Number's safe range");
      return { type: "integer", ...empty, integer: String(value) };
    }
    return { type: "real", ...empty, real: value };
  }
  if (typeof value === "string") return { type: "text", ...empty, text: value };
  if (value instanceof Uint8Array) {
    let text = "";
    for (let i = 0; i < value.length; i += 8192) text += String.fromCharCode(...value.subarray(i, i + 8192));
    return { type: "blob", ...empty, blob: btoa(text) };
  }
  throw new TypeError("sqlite: unsupported parameter");
}

function decode(value: WireValue): Value {
  switch (value.type) {
    case "null":
      return null;
    case "integer": {
      const n = BigInt(value.integer!);
      return n >= BigInt(Number.MIN_SAFE_INTEGER) && n <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(n) : n;
    }
    case "real":
      return Number(value.special ?? value.real ?? 0);
    case "text":
      return value.text ?? "";
    case "blob":
      return Uint8Array.from(atob(value.blob ?? ""), (c) => c.charCodeAt(0));
  }
}
