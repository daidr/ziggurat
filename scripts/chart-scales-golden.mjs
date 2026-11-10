// Writes src/chart/testdata/log_scales.json.gz, the reference positions,
// inversions, ticks and nice domains of the chart's logarithmic and
// symmetric log scales, from d3-scale, which the scales follow. Run with
// Node, given a directory holding d3-scale 4.0.2:
//
//   npm install --prefix /tmp/chart-reference --ignore-scripts --no-audit --no-fund d3-scale@4.0.2
//   node scripts/chart-scales-golden.mjs /tmp/chart-reference
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { resolve, join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { gzipSync } from "node:zlib";

const root = process.argv[2];
if (!root) throw new Error("Pass the directory holding node_modules/d3-scale 4.0.2");
const pkg = resolve(root, "node_modules/d3-scale");
const { version } = JSON.parse(await readFile(join(pkg, "package.json"), "utf8"));
if (version !== "4.0.2") throw new Error(`Expected d3-scale 4.0.2, found ${version}`);
const { scaleLog, scaleSymlog } = await import(pathToFileURL(join(pkg, "src/index.js")).href);

// Fractions as f32 values, as the scales take them.
const fractions = [-0.5, 0, 0.1, 0.25, 0.5, 0.75, 0.9, 1, 1.5].map(Math.fround);
const both = (pairs) => pairs.flatMap(([lo, hi]) => [[lo, hi], [hi, lo]]);
const logDomains = [[1, 1000], [0.001, 1], [0.3, 1.2], [30, 90], [1, 1], [1e-12, 1e12], [1e6, 3.4e6], [Number.MIN_VALUE, 1], [1e-320, 1e-300]];
const cases = [];
for (const kind of ["log", "symlog"]) {
  const domains = kind === "log"
    ? both(logDomains.flatMap(([lo, hi]) => [[lo, hi], [-hi, -lo]]))
    : both([[0, 100], [-100, 100], [-100, -1], [-1e6, 1e6], [3.2, 7.9], [0, 0]]);
  const parameters = kind === "log" ? [2, Math.E, 10, 16, 100] : [0.01, 1, 10, 100];
  for (const domain of domains) for (const parameter of parameters) for (const count of [1, 2, 5, 10]) for (const clamp of [false, true]) {
    const scale = kind === "log" ? scaleLog().base(parameter) : scaleSymlog().constant(parameter);
    scale.domain(domain).clamp(clamp);
    const raw = scale.copy().clamp(false);
    // Past the ends of a subnormal domain values underflow or overflow:
    // sample within it there.
    const fs = domain.some((v) => v !== 0 && Math.abs(v) < 1e-300) ? fractions.filter((f) => f >= 0 && f <= 1) : fractions;
    const values = fs.map((f) => raw.invert(f));
    cases.push({
      kind, domain, parameter, count, clamp,
      values, positions: values.map((v) => scale(v)),
      fractions: fs, inversions: fs.map((f) => scale.invert(f)),
      ticks: scale.ticks(count), nice: scale.copy().nice(count).domain(),
    });
  }
}
const out = resolve(dirname(fileURLToPath(import.meta.url)), "../src/chart/testdata");
await mkdir(out, { recursive: true });
await writeFile(join(out, "log_scales.json.gz"), gzipSync(JSON.stringify({ version, cases }) + "\n", { level: 9 }));
console.log(`${cases.length} cases from d3-scale ${version}`);
