import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// The host evaluates src/page_runtime/find.js in the page; its matcher is
// pure and runs here without a DOM.
const source = readFileSync(join(import.meta.dir, "../../../src/page_runtime/find.js"), "utf8");
const window: Record<string, unknown> = {};
new Function("window", source)(window);
const finder = window.__zigguratFind as {
  search(text: string, needle: string, matchCase: boolean): { offsets: number[]; length: number };
  find(text: string, options: object): { matches: number; active: number };
};

test("the finder installs once and freezes", () => {
  new Function("window", source)(window);
  expect(window.__zigguratFind).toBe(finder);
  expect(Object.isFrozen(finder)).toBe(true);
});

test("matches do not overlap and follow the case option", () => {
  expect(finder.search("Banana bAnAnA", "ana", false)).toEqual({ offsets: [1, 8], length: 3 });
  expect(finder.search("Banana bAnAnA", "ana", true)).toEqual({ offsets: [1], length: 3 });
  expect(finder.search("aaaa", "aa", false).offsets).toEqual([0, 2]);
  expect(finder.search("abc", "", false).offsets).toEqual([]);
  // Lower-casing İ changes the length; the search falls back to exact text.
  expect(finder.search("İstanbul", "stan", false).offsets).toEqual([1]);
});

test("an empty search finds nothing without touching the page", () => {
  expect(finder.find("", {})).toEqual({ matches: 0, active: 0 });
});
