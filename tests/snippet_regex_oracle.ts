// Development-only native RegExp oracle. Writes a standalone Zig test to an
// explicitly supplied path; no runtime or editor dependency is introduced.
const output = process.argv[2];
if (!output) throw new Error("usage: bun tests/snippet_regex_oracle.ts <output.zig>");
type TestCase = { pattern: string; flags: string; text: string; matches: (readonly [number, number] | undefined)[][] };
const cases: TestCase[] = [];
const add = (pattern: string, flags: string, text: string) => {
  const expression = new RegExp(pattern, `${flags}d`);
  const matches: TestCase["matches"] = [];
  let found: RegExpExecArray | null;
  while ((found = expression.exec(text))) {
    matches.push([...found.indices!]);
    if (!expression.global) break;
    if (found[0] === "") {
      const at = expression.lastIndex;
      const point = text.codePointAt(at);
      expression.lastIndex += expression.unicode && point !== undefined && point > 0xffff ? 2 : 1;
    }
  }
  cases.push({ pattern, flags, text, matches });
};
const patterns = [
  "", "a|aa", "(a|aa)+", "(aa|a)+?", "a*", "a*?", "a+?b", "a{1,3}", "a{0,3}?b",
  "(a|(b))+", "((ab)|(a))+(b)?", "(a(b)?|c(d)?)+", "(a|b){1,3}?b", "(a|b){0,3}a",
  "(z)((a+)?(b+)?(c))*", "(.*)\\..+$", "[a-c]+", "[^a-c]+", "[a-z\\d_]+",
  "[\\s\\D]+", "\\b\\w+\\b", "\\B.", "^a.*$", "a$", "^.$", "(?:a|b)+?c",
  "(a+?)(a+)", "(.)", "😀+", "[😀a]+", "\\uD83D\\uDE00+", "\\s", ".*?",
];
const texts = ["", "aaab", "zaacbbbcac", "a\r\nb", "\r\n", "猫-file.txt", "😀a😀", "\u2028a\u2029", "\ufeff", "\u180e", "\u0085", "ABC_123"];
for (const pattern of patterns) for (const flags of ["", "g", "gm", "gs", "gu", "gmu"]) for (const text of texts) add(pattern, flags, text);
for (const pattern of ["[a-z]+", "[^A-Z]+", "\\b[a-z]+\\b", "(a|B)+", "[\\w\\s]+", "[^\\W]+"])
  for (const flags of ["i", "gi", "gimu"]) for (const text of ["", "ABC_123", "aBc", "a\r\nB", "!A!", "_"]) add(pattern, flags, text);
let seed = 0x214478a1;
const random = (max: number) => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return (seed >>> 0) % max; };
for (let n = 0; n < 1500; n++) {
  const pattern = patterns[random(patterns.length)]!;
  let text = "";
  for (let i = random(13); i > 0; i--) text += ["a", "b", "c", "d", "z", "\n", "\r", "😀", " "][random(9)];
  add(pattern, ["", "g", "gm", "gs", "gu", "gmu"][random(6)]!, text);
}
const zigString = (value: string) => `"${[...new TextEncoder().encode(value)].map(b => b >= 0x20 && b <= 0x7e && b !== 34 && b !== 92 ? String.fromCharCode(b) : `\\x${b.toString(16).padStart(2, "0")}`).join("")}"`;
const range = (value: readonly [number, number] | undefined) => value ? `.{.start=${value[0]},.end=${value[1]}}` : "null";
const source = `const std=@import("std");
const regex=@import("snippet_regex");
const Case=struct{pattern:[]const u8,flags:[]const u8,text:[]const u8,matches:[]const []const ?regex.Range};
const cases=[_]Case{
${cases.map(c => `.{.pattern=${zigString(c.pattern)},.flags=${zigString(c.flags)},.text=${zigString(c.text)},.matches=&.{${c.matches.map(m => `&.{${m.map(range).join(",")}}`).join(",")}}}`).join(",\n")}
};
test "native RegExp differential indices and capture clearing" {
 var workspace=try regex.Workspace.init(std.testing.allocator,.{}); defer workspace.deinit() catch unreachable;
 for(cases,0..) |case,index| {
  var program=try regex.Program.compile(std.testing.allocator,case.pattern,case.flags,.{}); defer program.deinit() catch unreachable;
  var work:regex.Work=.{.limit=8*1024*1024}; var cursor=try workspace.begin(&program,case.text,&work); defer cursor.end();
  var count:usize=0;
  while(try cursor.next()) |match| : (count+=1) {
   if(count>=case.matches.len) {std.debug.print("extra match case {d}: {s} flags={s} text={s}\\n",.{index,case.pattern,case.flags,case.text});return error.OracleMismatch;}
   for(case.matches[count],0..) |expected,capture| if(!std.meta.eql(expected,match.capture(capture))) {std.debug.print("case {d}: {s} flags={s} text={s} match={d} capture={d} expected={any} actual={any}\\n",.{index,case.pattern,case.flags,case.text,count,capture,expected,match.capture(capture)});return error.OracleMismatch;};
  }
  if(count!=case.matches.len) {std.debug.print("missing match case {d}: {s} flags={s} text={s} expected={d} actual={d}\\n",.{index,case.pattern,case.flags,case.text,case.matches.len,count});return error.OracleMismatch;}
 }
}
`;
await Bun.write(output, source);
console.log(`wrote ${cases.length} native oracle cases`);
if (process.argv[3]) {
  const formats = [
    { source: "$0", fallback: false, render: (c: string[]) => c[0] ?? "" },
    { source: "<$1>-${2}", fallback: false, render: (c: string[]) => `<${c[1] ?? ""}>-${c[2] ?? ""}` },
    { source: "${1:?yes:no}", fallback: true, render: (c: string[]) => c[1] ? "yes" : "no" },
    { source: "${1:+yes}${2:-fallback}", fallback: true, render: (c: string[]) => `${c[1] ? "yes" : ""}${c[2] ? "" : "fallback"}` },
    { source: "pre-${1:?yes:}-post", fallback: false, render: (c: string[]) => `pre-${c[1] ? "yes" : ""}-post` },
    { source: "${0:/upcase}", fallback: false, ascii: true, render: (c: string[]) => (c[0] ?? "").toUpperCase() },
    { source: "${1:/downcase}", fallback: false, ascii: true, render: (c: string[]) => (c[1] ?? "").toLowerCase() },
  ];
  const transformed: { pattern: string; flags: string; format: string; text: string; expected: string | null }[] = [];
  for (let index = 0; index < cases.length; index += 3) {
    const c = cases[index]!;
    for (const f of formats) {
      if (f.ascii && /[^\x00-\x7f]/.test(c.text)) continue;
      let matched = false;
      let expected = c.text.replace(new RegExp(c.pattern, c.flags), (...args) => { matched = true; return f.render(args.slice(0, -2)); });
      if (!matched && f.fallback) expected = f.render([]);
      // Ill-formed UTF16 is an explicit error at the UTF8 output boundary.
      transformed.push({ pattern: c.pattern, flags: c.flags, format: f.source, text: c.text, expected: expected.isWellFormed() ? expected : null });
    }
  }
  const transformSource = `const std=@import("std");const engine=@import("snippet_transform");
const Case=struct{pattern:[]const u8,flags:[]const u8,format:[]const u8,text:[]const u8,expected:?[]const u8};
const cases=[_]Case{${transformed.map(c => `.{.pattern=${zigString(c.pattern)},.flags=${zigString(c.flags)},.format=${zigString(c.format)},.text=${zigString(c.text)},.expected=${c.expected === null ? "null" : zigString(c.expected)}}`).join(",\n")}};
test "native global substitution and independent format cases"{
 var runtime=try engine.Runtime.init(std.testing.allocator,.{}); defer runtime.deinit() catch unreachable;
 var output:[16384]u8=undefined;
 for(cases,0..) |case,index| {
  var transform=try engine.Transform.compile(std.testing.allocator,case.pattern,case.format,case.flags,.{}); defer transform.deinit() catch unreachable;
  var work:engine.regex.Work=.{.limit=8*1024*1024};
  const actual=runtime.applyInto(&transform,case.text,&output,&work) catch |err| {if(case.expected==null and err==error.UnsupportedSurrogateResult)continue;std.debug.print("case {d} unexpected {s}\\n",.{index,@errorName(err)});return err;};
  if(case.expected==null or !std.mem.eql(u8,case.expected.?,actual)){std.debug.print("case {d}: {s}/{s} format={s} text={s} expected={?s} actual={s}\\n",.{index,case.pattern,case.flags,case.format,case.text,case.expected,actual});return error.OracleMismatch;}
 }
}
`;
  await Bun.write(process.argv[3], transformSource);
  console.log(`wrote ${transformed.length} native substitution oracle cases`);
}
