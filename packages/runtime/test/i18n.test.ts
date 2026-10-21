import { expect, test } from "bun:test";
import { createCatalog, direction, fallbackChain, formatMessage, MessageError, negotiate, parseLocale, validateMessage } from "../src/i18n";

// The cases of the Zig module's own message tests: both sides agree.
test("simple arguments and quoting", () => {
  expect(formatMessage("en", "Hello, {name}!", { name: "Ana" })).toBe("Hello, Ana!");
  expect(formatMessage("en", "{a} and {b}", { a: 1234, b: 0.5 })).toBe("1,234 and 0.5");
  expect(formatMessage("en", "It''s '{literal}' and '#' #")).toBe("It's {literal} and '#' #");
  expect(formatMessage("en", "don't")).toBe("don't");
  expect(formatMessage("de", "{n, number} / {n, number, integer} / {p, number, percent}", { n: 1234.56, p: 0.25 })).toBe("1.234,56 / 1.235 / 25\u00A0%");
});

test("plural selection, offsets and number sign", () => {
  const files = "{count, plural, =0 {No files} one {# file} other {# files}}";
  expect(formatMessage("en", files, { count: 0 })).toBe("No files");
  expect(formatMessage("en", files, { count: 1 })).toBe("1 file");
  expect(formatMessage("en", files, { count: 1200 })).toBe("1,200 files");
  expect(formatMessage("en", files, { count: 1.5 })).toBe("1.5 files");
  expect(formatMessage("en", files, { count: 2n })).toBe("2 files");
  const ru = "{n, plural, one {# файл} few {# файла} many {# файлов} other {# файла}}";
  expect(formatMessage("ru", ru, { n: 21 })).toBe("21 файл");
  expect(formatMessage("ru", ru, { n: 3 })).toBe("3 файла");
  expect(formatMessage("ru", ru, { n: 11 })).toBe("11 файлов");
  expect(formatMessage("ru", ru, { n: 2.5 })).toBe("2,5 файла");
  const guests = "{n, plural, offset:1 =0 {nobody} =1 {{host}} one {{host} and # other} other {{host} and # others}}";
  expect(formatMessage("en", guests, { n: 1, host: "Kim" })).toBe("Kim");
  expect(formatMessage("en", guests, { n: 2, host: "Kim" })).toBe("Kim and 1 other");
  expect(formatMessage("en", guests, { n: 5, host: "Kim" })).toBe("Kim and 4 others");
  const ordinal = "{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}";
  expect(formatMessage("en", ordinal, { n: 23 })).toBe("23rd");
  expect(formatMessage("en", ordinal, { n: 11 })).toBe("11th");
  expect(formatMessage("en", "{n, plural, other {'#' is #}}", { n: 2 })).toBe("# is 2");
  expect(formatMessage("ar", "{n, plural, zero {صفر} one {واحد} two {اثنان} few {# قليل} many {# كثير} other {#}}", { n: 0 })).toBe("صفر");
});

test("select, nesting and dates", () => {
  const pattern = "{gender, select, female {{n, plural, one {She has one} other {She has #}}} male {He has {n}} other {They have {n}}}";
  expect(formatMessage("en", pattern, { gender: "female", n: 1 })).toBe("She has one");
  expect(formatMessage("en", pattern, { gender: "male", n: 3 })).toBe("He has 3");
  expect(formatMessage("en", pattern, { gender: "x", n: 3 })).toBe("They have 3");
  const when = new Date(2024, 2, 5, 15, 7, 9);
  // Engines' ICU data differ in the space before AM/PM.
  expect(formatMessage("en", "Saved {d, date, long} at {d, time, short}", { d: when }).replace("\u202F", " ")).toBe("Saved March 5, 2024 at 3:07 PM");
  expect(formatMessage("de", "{d, date}", { d: when })).toBe("05.03.2024");
});

test("syntax errors and argument errors", () => {
  for (const bad of ["{", "}", "{name", "{1x, foo}", "{n, plural, one {x}}", "{n, plural, other {x} other {y}}", "{n, select, a {x}}", "{n, number, money}", "{n, date, tiny}", "{n, plural, other {x}", "{n, plural, =a {x} other {y}}", "{ }", "{n,}", "{n, plural, bogus {x} other {y}}"]) {
    expect(() => formatMessage("en", bad, { n: 1 })).toThrow(MessageError);
    expect(() => validateMessage(bad)).toThrow("InvalidMessage");
  }
  const deep = "{a,select,other{".repeat(8) + "{a}" + "}}".repeat(8);
  expect(() => validateMessage(deep)).toThrow("NestingTooDeep");
  validateMessage("{a,select,other{".repeat(7) + "{a}" + "}}".repeat(7));
  const code = (f: () => unknown) => {
    try {
      f();
    } catch (error) {
      return (error as MessageError).code;
    }
  };
  expect(code(() => formatMessage("en", "{x}"))).toBe("MissingArgument");
  expect(code(() => formatMessage("en", "{x, number}", { x: "a" }))).toBe("ArgumentType");
  expect(code(() => formatMessage("en", "{x, select, other {}}", { x: 1 }))).toBe("ArgumentType");
  expect(code(() => formatMessage("en", "{x, date}", { x: 1 }))).toBe("ArgumentType");
  expect(code(() => validateMessage("x".repeat(16 * 1024 + 1)))).toBe("InvalidMessage");
});

test("pseudolocalization and bidi isolation", () => {
  expect(formatMessage("en-XA", "Hi {name}, {n, plural, one {# new} other {# new}}", { name: "Bo", n: 2 }, { pseudo: "accented" })).toBe("[Ĥî Bo, 2 ñéŵ ~~~~]");
  expect(formatMessage("en", "Open", {}, { pseudo: "bidi" })).toBe("\u200F\u202EOpen\u202C\u200F");
  expect(formatMessage("he", "שלום {name}", { name: "Ana" })).toBe("שלום \u2068Ana\u2069");
  expect(formatMessage("he", "שלום {name}", { name: "Ana" }, { isolateArguments: false })).toBe("שלום Ana");
});

test("locales parse, fall back and negotiate like the Zig module", () => {
  expect(parseLocale("EN_us.UTF-8@euro").tag).toBe("en-US");
  expect(parseLocale("zh-hant-tw").tag).toBe("zh-Hant-TW");
  expect(parseLocale("C").tag).toBe("");
  expect(parseLocale("de-CH-1996-x-private").tag).toBe("de-CH-1996");
  for (const bad of ["", "e", "en--US", "-en", "en-", "123"]) expect(() => parseLocale(bad)).toThrow(MessageError);
  expect(fallbackChain("de-CH-1996")).toEqual(["de-CH-1996", "de-CH", "de"]);
  expect(fallbackChain("zh-TW")).toEqual(["zh-TW", "zh-Hant-TW", "zh-Hant"]);
  expect(fallbackChain("sr-Latn")).toEqual(["sr-Latn"]);
  expect(fallbackChain("zh-Hans-CN")).toEqual(["zh-Hans-CN", "zh-CN", "zh-Hans", "zh"]);
  expect(negotiate(["en"], ["de", "en-US"])).toBe(1);
  expect(negotiate(["zh-HK"], ["zh", "zh-TW"])).toBe(1);
  expect(negotiate(["fr"], ["de"])).toBe(-1);
  expect(direction("ar")).toBe("rtl");
  expect(direction("en-XB")).toBe("rtl");
  expect(direction("az-Arab")).toBe("rtl");
  expect(direction("ja")).toBe("ltr");
});

test("catalogs resolve through display and source chains", () => {
  const catalog = createCatalog({
    source: "en",
    messages: {
      en: { greeting: "Hello, {name}!", files: "{n, plural, one {# file} other {# files}}", menu: { open: "Open" } },
      de: { greeting: "Hallo, {name}!", count: "{n, number}" },
    },
  });
  expect(catalog.locales).toEqual(["en", "de"]);
  expect(catalog.negotiate(["de-AT", "en"])).toBe("de");
  expect(catalog.negotiate(["fr"])).toBe("en");
  const swiss = catalog.localizer("de-CH");
  expect(swiss.format("greeting", { name: "Ana" })).toBe("Hallo, Ana!");
  // A de message keeps the display locale's digits; a source fallback
  // keeps English conventions.
  expect(swiss.format("count", { n: 1234.5 })).toBe(formatMessage("de-CH", "{n, number}", { n: 1234.5 }));
  expect(swiss.format("files", { n: 1200 })).toBe("1,200 files");
  expect(swiss.format("menu.open")).toBe("Open");
  expect(swiss.format("missing.key")).toBe("missing.key");
  expect(swiss.has("missing.key")).toBe(false);
  const pseudo = catalog.localizer("en-XA");
  expect(pseudo.format("menu.open")).toBe("[Öþéñ ~~]");
  expect(catalog.localizer("ar-XB").direction).toBe("rtl");
  expect(() => createCatalog({ source: "en", messages: { en: { bad: "{n, plural, one {x}}" } } })).toThrow("bad");
  expect(() => createCatalog({ source: "en", messages: { en: { "a.b": "x", a: { b: "y" } } } })).toThrow("duplicate");
  expect(() => createCatalog({ source: "en", messages: { en: {}, EN: {} } })).toThrow("Duplicate locale");
});

test("message functions follow the page's language", () => {
  const catalog = createCatalog({
    source: "en",
    messages: { en: { files: "{n, plural, one {# file} other {# files}}", hello: "Hello, {name}!" }, de: { hello: "Hallo, {name}!" } },
    params: { files: ["n"] },
  });
  const shared = Symbol.for("ziggurat.runtime");
  const holder = globalThis as unknown as Record<symbol, unknown>;
  const saved = holder[shared];
  holder[shared] = { connection: { runtime: { locale: "de-AT" } } };
  try {
    const messages = catalog.messages<{ files(n: number): string; hello(args: { name: string }): string }>();
    expect(messages.hello({ name: "Ana" })).toBe("Hallo, Ana!");
    expect(messages.files(2)).toBe("2 files");
    (holder[shared] as { connection: { runtime: { locale: string } } }).connection.runtime.locale = "fr";
    expect(messages.hello({ name: "Ana" })).toBe("Hello, Ana!");
    const pseudo = catalog.messagesIn<{ hello(args: { name: string }): string }>("en-XA");
    expect(pseudo.hello({ name: "Bo" })).toBe("[Ĥéļļö, Bo! ~~~~]");
  } finally {
    holder[shared] = saved;
  }
});
