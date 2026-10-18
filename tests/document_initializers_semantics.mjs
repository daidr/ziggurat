import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import vm from "node:vm";

// Pass the emitter directly, or a launcher followed by its fixed arguments:
// node tests/document_initializers_semantics.mjs wsl -d Ubuntu-24.04 -- /path/emitter
const command = process.argv[2];
const launcherArguments = process.argv.slice(3);
assert.ok(command, "expected an initializer source emitter command");
function emit(kind) {
  const result = spawnSync(command, [...launcherArguments, kind], {
    encoding: "utf8",
    timeout: 10000,
    maxBuffer: 1024 * 1024,
    windowsHide: true,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}
function document({ origin = "https://example.test", protocol = "https:", frame = false, originGetter } = {}) {
  const window = { order: [] };
  window.top = frame ? {} : window;
  const location = { protocol, origin };
  if (originGetter) Object.defineProperty(location, "origin", { get: originGetter });
  return { window, context: vm.createContext({ window, location }, { codeGeneration: { strings: false, wasm: false } }) };
}
function execute(program, options) {
  const target = document(options);
  new vm.Script(program, { filename: "owned-initializer-batch.js" }).runInContext(target.context, { timeout: 100 });
  return target.window.order;
}
let assertions = 0;
const equal = (actual, expected) => { assert.deepEqual(actual, expected); assertions++; };
const returns = emit("return");
equal(execute(returns), ["甲😀", "undefined"]);
const guards = emit("guard");
equal(execute(guards), ["first", "second"]);
for (const options of [
  { frame: true },
  { origin: "https://other.test" },
  { origin: "null" },
  { origin: "null", protocol: "about:" },
  { origin: "https://example.test", protocol: "http:" },
]) equal(execute(guards, options), []);
let reads = 0;
equal(execute(guards, { originGetter() { return reads++ === 0 ? "https://example.test" : "https://other.test"; } }), ["first"]);
equal(reads, 2);
const throwing = document();
assert.throws(() => new vm.Script(emit("throw")).runInContext(throwing.context, { timeout: 100 }), /expected-init-throw/);
assertions++;
equal(throwing.window.order, ["before-throw"]);
for (const kind of ["await", "import"]) {
  assert.throws(() => new vm.Script(emit(kind)), SyntaxError);
  assertions++;
}
// An invalid ordinary body can escape the wrapper while the combined program
// stays valid. This negative contract example must not become a security claim.
equal(execute(emit("invalid-body"), { origin: "https://other.test" }), ["outside-invalid-body"]);
console.log(`initializer JavaScript compiler oracle passed: ${assertions} assertions; ordinary function return/throw/locals, Unicode/comment boundary, per-body exact top/HTTPS guards, unsupported module syntax, string code generation disabled`);
console.log("Invalid-body negative example confirmed: guards and function semantics require trusted, syntactically valid ordinary function bodies; this wrapper is not an untrusted-code sandbox.");
console.log("This VM oracle does not establish browser injection timing, native Add/Remove, real frame origins, CSP bypass, or Runtime support.");
