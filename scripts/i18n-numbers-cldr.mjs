// Generates src/i18n/cldr_numbers.zig, the compact notation and currency
// data of the locales src/i18n/number.zig lists, from the CLDR data of the
// JavaScript engine's Intl (ICU), and src/i18n/testdata/numbers.json, the
// outputs the tests compare with.
//
//     bun scripts/i18n-numbers-cldr.mjs   (or node)
import { writeFileSync, mkdirSync } from "node:fs";

const locales = ["en", "en-IN", "hi", "de", "de-CH", "fr", "es", "es-MX", "it", "pt", "pt-PT", "nl", "ru", "uk", "pl", "cs", "sv", "nb", "fi", "da", "tr", "ja", "zh", "ko", "he", "ar", "fa"];
const currencies = ["USD", "EUR", "GBP", "JPY", "CNY", "KRW", "INR", "CHF", "CAD", "AUD", "HKD", "SGD", "NZD", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF", "RUB", "UAH", "TRY", "BRL", "MXN", "ILS", "SAR", "AED", "IRR", "TWD", "ZAR", "THB", "KWD", "BHD"];
const categories = ["zero", "one", "two", "few", "many", "other"];
const NUMBER = "\x01", CURRENCY = "\x02", MINUS = "\x03";
const numberParts = new Set(["integer", "group", "decimal", "fraction"]);

const zig = (s) => '"' + Array.from(s).map((c) => {
  const p = c.codePointAt(0);
  if (c === '"' || c === "\\") return "\\" + c;
  if (p < 0x20 || p === 0x7f) return "\\x" + p.toString(16).padStart(2, "0");
  if (p >= 0x80 && (p < 0xa1 || (p >= 0x200b && p <= 0x200f) || (p >= 0x202a && p <= 0x202f) || p === 0x061c || p === 0x2066 || p === 0x2069)) return "\\u{" + p.toString(16) + "}";
  return c;
}).join("") + '"';

// A template of parts: the number's digits as one NUMBER, the currency as
// CURRENCY, the minus sign as MINUS, literals as they are.
const template = (parts, compactAsLiteral = true) => {
  let out = "", inNumber = false;
  for (const part of parts) {
    if (numberParts.has(part.type)) {
      if (!inNumber) out += NUMBER;
      inNumber = true;
      continue;
    }
    inNumber = false;
    if (part.type === "currency") out += CURRENCY;
    // The engine's minus sign symbol carries its bidi mark ("\u200e-"),
    // which formatToParts reports as a literal before it.
    else if (part.type === "minusSign") out = out.replace(/[\u200e\u200f\u061c]$/u, "") + MINUS;
    else if (part.type === "compact" && !compactAsLiteral) out += "\x04";
    else out += part.value;
  }
  return out;
};

const plural = (locale) => new Intl.PluralRules(locale);
const sample = (locale, category, from, to) => {
  const rules = plural(locale);
  for (let n = from; n < to; n++) if (rules.select(n) === category) return n;
  return null;
};

// Compact notation: for each power of ten from 10^3 to 10^14, the power the
// number is divided by and the affixes of each plural category.
function compact(locale, display) {
  const rows = [];
  for (let e = 3; e <= 14; e++) {
    const f = new Intl.NumberFormat(locale, { notation: "compact", compactDisplay: display, maximumFractionDigits: 0, useGrouping: false, numberingSystem: "latn" });
    // Two of the power, as 10^3 alone may take a form without digits
    // ("mille" in Italian), which is kept as `one`.
    const parts = f.formatToParts(2 * 10 ** e);
    if (!parts.some((p) => p.type === "compact")) {
      rows.push(null);
      continue;
    }
    const digits = parts.filter((p) => p.type === "integer").map((p) => p.value).join("");
    const zeros = e - (digits.length - 1);
    const exact = template(f.formatToParts(10 ** zeros));
    const one = exact.includes(NUMBER) ? null : exact;
    // Italian's "mille" is the one form, which -1000 takes too; French
    // keeps it for exactly 1000 ("-1 millier").
    const oneNegative = one !== null && !template(f.formatToParts(-(10 ** zeros))).includes(NUMBER);
    const decimal = plural(locale).select(1.5);
    const fraction = new Intl.NumberFormat(locale, { notation: "compact", compactDisplay: display, maximumFractionDigits: 1, useGrouping: false, numberingSystem: "latn" });
    const forms = categories.map((category) => {
      const m = sample(locale, category, 10 ** (digits.length - 1), 10 ** digits.length);
      // A category of decimals alone, as Russian's other: 1.5 thousand.
      if (m === null && category === decimal && digits.length === 1) {
        const t = template(fraction.formatToParts(1.5 * 10 ** zeros));
        const at = t.indexOf(NUMBER);
        return [t.slice(0, at), t.slice(at + 1)];
      }
      if (m === null) return null;
      let t = template(f.formatToParts(m * 10 ** zeros));
      // The one's form was the bare word: take the category from 1.5.
      if (!t.includes(NUMBER)) t = template(fraction.formatToParts(1.5 * 10 ** zeros));
      const at = t.indexOf(NUMBER);
      return [t.slice(0, at), t.slice(at + 1)];
    });
    rows.push({ zeros, forms, one, oneNegative });
  }
  return rows;
}

const money = (locale, currency, display, sign, value) =>
  new Intl.NumberFormat(locale, { style: "currency", currency, currencyDisplay: display, currencySign: sign, numberingSystem: "latn" }).formatToParts(value);

function currencyTemplates(locale) {
  const out = {};
  for (const [display, currency, value] of [["narrowSymbol", "USD", 1234.5], ["code", "EUR", 1234.5], ["name", "EUR", 1234.5]]) {
    for (const sign of ["standard", "accounting"]) {
      out[(display === "narrowSymbol" ? "symbol" : display) + "_" + sign] = [template(money(locale, currency, display, sign, value)), template(money(locale, currency, display, sign, -value))];
    }
  }
  return out;
}

function currencyNames(locale, code) {
  const symbol = money(locale, code, "symbol", "standard", 1).find((p) => p.type === "currency").value;
  const narrow = money(locale, code, "narrowSymbol", "standard", 1).find((p) => p.type === "currency").value;
  const names = categories.map((category) => {
    const m = sample(locale, category, 0, 200);
    if (m === null) return null;
    return money(locale, code, "name", "standard", m).find((p) => p.type === "currency").value;
  });
  // Decimals take their own category, as 1.50 in English.
  const decimal = plural(locale).select(1.5);
  const decimalName = money(locale, code, "name", "standard", 1.5).find((p) => p.type === "currency").value;
  if (names[categories.indexOf(decimal)] === null) names[categories.indexOf(decimal)] = decimalName;
  return { symbol, narrow, names };
}

const digitsOf = (code) => new Intl.NumberFormat("en", { style: "currency", currency: code }).resolvedOptions().maximumFractionDigits;

let z = `//! Compact notation and currency data of CLDR for the locales number.zig
//! lists. Generated by scripts/i18n-numbers-cldr.mjs from the CLDR data of
//! the JavaScript engine's Intl; do not edit.
//!
//! Templates mark the number with \\x01, the currency with \\x02 and the
//! minus sign with \\x03; the rest is literal.

pub const Affix = struct { prefix: []const u8, suffix: []const u8 };
/// A power of ten in compact notation: the power the number is divided by,
/// and the affixes of each plural category (plural.Category's order).
pub const Power = struct {
    zeros: u8,
    forms: [6]?Affix,
    /// The whole text of exactly one of the power where CLDR spells it
    /// without digits, and whether minus one takes it too.
    one: ?[]const u8 = null,
    one_negative: bool = false,
};
pub const Compact = struct { tag: []const u8, short: [12]?Power, long: [12]?Power };
pub const Templates = struct { positive: []const u8, negative: []const u8 };
pub const CurrencyTemplates = struct {
    tag: []const u8,
    symbol: Templates,
    symbol_accounting: Templates,
    code: Templates,
    code_accounting: Templates,
    name: Templates,
    name_accounting: Templates,
};
pub const CurrencyName = struct { code: []const u8, symbol: []const u8, narrow: []const u8, names: [6]?[]const u8 };
pub const LocaleCurrencies = struct { tag: []const u8, names: []const CurrencyName };
pub const Fraction = struct { code: []const u8, digits: u8 };

`;
const power = (p) => p === null ? "null" : `.{ .zeros = ${p.zeros}, .forms = .{ ${p.forms.map((f) => f === null ? "null" : `Affix{ .prefix = ${zig(f[0])}, .suffix = ${zig(f[1])} }`).join(", ")} }${p.one === null ? "" : `, .one = ${zig(p.one)}, .one_negative = ${p.oneNegative}`} }`;
z += "pub const compact = [_]Compact{\n";
for (const l of locales) z += `    .{ .tag = ${zig(l)}, .short = .{ ${compact(l, "short").map(power).join(", ")} }, .long = .{ ${compact(l, "long").map(power).join(", ")} } },\n`;
z += "};\n\npub const currency_templates = [_]CurrencyTemplates{\n";
for (const l of locales) {
  const t = currencyTemplates(l);
  const pair = (k) => `.{ .positive = ${zig(t[k][0])}, .negative = ${zig(t[k][1])} }`;
  z += `    .{ .tag = ${zig(l)}, .symbol = ${pair("symbol_standard")}, .symbol_accounting = ${pair("symbol_accounting")}, .code = ${pair("code_standard")}, .code_accounting = ${pair("code_accounting")}, .name = ${pair("name_standard")}, .name_accounting = ${pair("name_accounting")} },\n`;
}
z += "};\n\npub const currency_names = [_]LocaleCurrencies{\n";
for (const l of locales) {
  z += `    .{ .tag = ${zig(l)}, .names = &.{\n`;
  for (const c of currencies) {
    const n = currencyNames(l, c);
    z += `        .{ .code = "${c}", .symbol = ${zig(n.symbol)}, .narrow = ${zig(n.narrow)}, .names = .{ ${n.names.map((x) => x === null ? "null" : zig(x)).join(", ")} } },\n`;
  }
  z += "    } },\n";
}
z += "};\n\n/// Fraction digits of currencies other than two.\npub const fractions = [_]Fraction{\n";
for (const c of currencies) if (digitsOf(c) !== 2) z += `    .{ .code = "${c}", .digits = ${digitsOf(c)} },\n`;
z += "};\n";
writeFileSync(new URL("../src/i18n/cldr_numbers.zig", import.meta.url), z);

// Outputs to compare with.
const cases = [];
const values = [1, 999, 1234, 15300, 999999, 1234567, 21000000, 7.25e9, -1500, -2.5e6];
for (const l of locales) {
  // Plain numbers, to tell the locales whose digits and separators differ
  // from the engine's (the test skips those).
  for (const v of [1234.5, -1234.5, 12345.5]) cases.push({ locale: l, kind: "decimal", value: v, want: new Intl.NumberFormat(l, { numberingSystem: "latn" }).format(v) });
  for (const display of ["short", "long"]) for (const v of [...values, 1000, -1000]) {
    cases.push({ locale: l, kind: "compact", display, value: v, want: new Intl.NumberFormat(l, { notation: "compact", compactDisplay: display, numberingSystem: "latn" }).format(v) });
  }
  for (const c of ["USD", "EUR", "JPY", "CHF"]) for (const display of ["symbol", "narrowSymbol", "code", "name"]) for (const [sign, v] of [["standard", 1], ["standard", 1234.56], ["standard", -1234.56], ["accounting", -1234.56]]) {
    cases.push({ locale: l, kind: "currency", currency: c, display, sign, value: v, want: new Intl.NumberFormat(l, { style: "currency", currency: c, currencyDisplay: display, currencySign: sign, numberingSystem: "latn" }).format(v) });
  }
  for (const v of [1234.56, 2.1e6]) cases.push({ locale: l, kind: "compact-currency", currency: "USD", display: "short", value: v, want: new Intl.NumberFormat(l, { style: "currency", currency: "USD", notation: "compact", numberingSystem: "latn" }).format(v) });
}
mkdirSync(new URL("../src/i18n/testdata/", import.meta.url), { recursive: true });
writeFileSync(new URL("../src/i18n/testdata/numbers.json", import.meta.url), JSON.stringify(cases, null, 0).replaceAll("},{", "},\n{") + "\n");
console.log(cases.length + " cases");
