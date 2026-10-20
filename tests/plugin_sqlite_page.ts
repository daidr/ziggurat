import { connect } from "../packages/runtime/src/index";
import { open, SqliteError } from "../packages/plugin-sqlite/src/index";

declare const chrome: { webview: { postMessage(message: string): void } };
const say = (message: string) => chrome.webview.postMessage(message);
const check = (condition: boolean, name: string) => {
  if (!condition) throw new Error(name);
};

let stage = "connect";
(async () => {
  await connect();

  stage = "denied";
  const denied = await open("../outside.db").catch((error: unknown) => error);
  check(denied instanceof SqliteError && denied.code === "denied", "Denied");

  stage = "write";
  const db = await open("notes/app.db");
  await db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL, body BLOB, big INTEGER)");
  const inserted = await db.execute("INSERT INTO notes (title, body, big) VALUES (?, ?, ?)", ["first", new Uint8Array([1, 2, 3]), 9007199254740993n]);
  check(inserted.changes === 1 && inserted.lastInsertId === 1n, "Inserted");

  stage = "transaction";
  const statements = Array.from({ length: 2000 }, (_, index) => ({ sql: "INSERT INTO notes (title) VALUES (?)", params: [`note ${index} ${"x".repeat(40)}`] }));
  for (let start = 0; start < statements.length; start += 100) await db.transaction(statements.slice(start, start + 100));
  const failed = await db.transaction([{ sql: "INSERT INTO notes (title) VALUES ('kept?')" }, { sql: "INSERT INTO notes (title) VALUES (NULL)" }]).catch((error: unknown) => error);
  check(failed instanceof SqliteError && failed.code === "sqlite", "RolledBack");

  stage = "query";
  const all = await db.query("SELECT id, title FROM notes ORDER BY id");
  check(all.rows.length === 2001 && all.columns.join() === "id,title", `Rows ${all.rows.length}`);
  check(all.rows[2000]![1] === `note 1999 ${"x".repeat(40)}`, "LastRow");
  const first = await db.query("SELECT body, big FROM notes WHERE id = ?", [1]);
  check(first.rows[0]![1] === 9007199254740993n, "BigInt");
  check(String(first.rows[0]![0]) === "1,2,3", "Blob");
  await db.close();

  stage = "read-only";
  const reader = await open("notes/app.db", { readOnly: true });
  const count = await reader.query("SELECT count(*) FROM notes WHERE title = 'kept?'");
  check(count.rows[0]![0] === 0, "Kept");
  const write = await reader.execute("DELETE FROM notes").catch((error: unknown) => error);
  check(write instanceof SqliteError && write.code === "sqlite", "ReadOnly");
  say("sq-done");
})().catch((error) => say(`sq-failed:${stage}: ${String(error)}`));
