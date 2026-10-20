/**
 * Messages of the app's catalogs, formatted in pages with the syntax, the
 * locale fallback and the pseudolocales of the Zig i18n module: the same
 * messages are valid, and invalid, on both sides. Plural categories,
 * numbers and dates use the browser's `Intl`.
 *
 * ```ts
 * import { createCatalog } from "@ziggurat/runtime/i18n";
 * import { connect } from "@ziggurat/runtime";
 *
 * const catalog = createCatalog({ source: "en", messages: { en: { files: "{count, plural, one {# file} other {# files}}" } } });
 * const text = catalog.localizer((await connect()).locale).format("files", { count: 3 });
 * ```
 *
 * @module
 */

export type MessageErrorCode = "InvalidMessage" | "NestingTooDeep" | "MissingArgument" | "ArgumentType" | "OutOfRange" | "InvalidLocale";

/** A message that does not parse, or arguments that do not fit it. */
export class MessageError extends Error {
  constructor(
    readonly code: MessageErrorCode,
    message: string = code,
  ) {
    super(message);
    this.name = "MessageError";
  }
}

/** Numbers (and bigints) for number/plural, strings for select, Dates for date/time. */
export type Argument = string | number | bigint | Date;
export type Arguments = Readonly<Record<string, Argument>>;
export type Direction = "ltr" | "rtl";
export type PseudoMode = "none" | "accented" | "bidi";

export interface FormatOptions {
  /**
   * Pseudolocalization. formatMessage defaults to none; a catalog's
   * localizer chooses by the region XA (accented) or XB (bidi).
   */
  pseudo?: PseudoMode;
  /** In right-to-left locales, isolate string arguments (default true). */
  isolateArguments?: boolean;
}

export const maxDepth = 8;
export const maxPatternBytes = 16 * 1024;

// ---------------------------------------------------------------------------
// Locales

/** A canonical language tag: lowercase language, titlecase script, uppercase region. */
export interface Locale {
  /** "" for the root locale. */
  readonly tag: string;
  readonly language: string;
  readonly script?: string;
  readonly region?: string;
  readonly variants: readonly string[];
}

const root: Locale = Object.freeze({ tag: "", language: "", variants: Object.freeze([]) });
const alpha = /^[A-Za-z]+$/;
const digits = /^[0-9]+$/;
const alnum = /^[A-Za-z0-9]+$/;

function compose(language: string, script?: string, region?: string, variants: readonly string[] = []): Locale {
  const lang = language.toLowerCase();
  const s = script ? script[0].toUpperCase() + script.slice(1).toLowerCase() : undefined;
  const r = region?.toUpperCase();
  const v = variants.map((x) => x.toLowerCase());
  const tag = [lang || "und", s, r, ...v].filter((x) => x !== undefined).join("-");
  return Object.freeze({ tag: tag.length > 32 ? invalidLocale(tag) : tag, language: lang, script: s, region: r, variants: Object.freeze(v) });
}

function invalidLocale(text: string): never {
  throw new MessageError("InvalidLocale", `Invalid locale: ${text}`);
}

/**
 * Parses a BCP 47 tag as the Zig module does: `-` or `_` separators, any
 * case, a POSIX `.codeset`/`@modifier` suffix; extensions and private use
 * are dropped; `und`, `root`, `C` and `POSIX` are the root locale.
 */
export function parseLocale(text: string): Locale {
  let source = text;
  const end = source.search(/[.@]/);
  if (end !== -1) source = source.slice(0, end);
  if (source.length === 0) invalidLocale(text);
  const lower = source.toLowerCase();
  if (lower === "root" || lower === "c" || lower === "posix") return root;
  if (/[-_]{2}/.test(source) || /^[-_]|[-_]$/.test(source)) invalidLocale(text);
  const parts = source.split(/[-_]/);
  const lang = parts[0];
  if (lang.length < 2 || lang.length > 8 || !alpha.test(lang)) invalidLocale(text);
  let script: string | undefined;
  let region: string | undefined;
  const variants: string[] = [];
  for (const part of parts.slice(1)) {
    if (part.length === 1) break;
    if (!script && !region && variants.length === 0 && part.length === 4 && alpha.test(part)) script = part;
    else if (!region && variants.length === 0 && ((part.length === 2 && alpha.test(part)) || (part.length === 3 && digits.test(part)))) region = part;
    else if (((part.length >= 5 && part.length <= 8) || (part.length === 4 && /^[0-9]/.test(part))) && alnum.test(part)) {
      if (variants.length === 4) invalidLocale(text);
      variants.push(part);
    } else invalidLocale(text);
  }
  const und = lang.toLowerCase() === "und";
  if (und && !script && !region && variants.length === 0) return root;
  return compose(und ? "" : lang, script, region, variants);
}

const rtlScripts = new Set(["Arab", "Hebr", "Thaa", "Syrc", "Nkoo", "Adlm", "Rohg", "Mand", "Samr", "Mend"]);
const likelyScripts: Record<string, string> = {
  ar: "Arab", fa: "Arab", ur: "Arab", ps: "Arab", ckb: "Arab", sd: "Arab", ug: "Arab",
  he: "Hebr", iw: "Hebr", yi: "Hebr", dv: "Thaa", syr: "Syrc",
  ru: "Cyrl", uk: "Cyrl", be: "Cyrl", bg: "Cyrl", mk: "Cyrl", sr: "Cyrl", kk: "Cyrl", mn: "Cyrl",
  el: "Grek", hy: "Armn", ka: "Geor", hi: "Deva", mr: "Deva", ne: "Deva", bn: "Beng", ta: "Taml",
  te: "Telu", th: "Thai", lo: "Laoo", km: "Khmr", my: "Mymr", am: "Ethi", ja: "Jpan", ko: "Kore",
};

/** The script a language is most likely written in, from the Zig module's small table. */
export function likelyScript(language: string, region?: string): string {
  if (language === "zh") return region === "TW" || region === "HK" || region === "MO" ? "Hant" : "Hans";
  return likelyScripts[language] ?? "Latn";
}

function effectiveScript(locale: Locale): string {
  return locale.script ?? likelyScript(locale.language, locale.region);
}

/** Right to left for RTL scripts, explicit or likely, and for the pseudo region XB. */
export function direction(tag: string | Locale): Direction {
  const locale = typeof tag === "string" ? parseLocale(tag) : tag;
  if (locale.region === "XB") return "rtl";
  return rtlScripts.has(effectiveScript(locale)) ? "rtl" : "ltr";
}

/**
 * Candidate tags from most to least specific, root excluded. A language is
 * not reached from a non-default script: zh-Hant never falls back to zh.
 */
export function fallbackChain(tag: string | Locale): string[] {
  const locale = typeof tag === "string" ? parseLocale(tag) : tag;
  const chain: string[] = [];
  if (locale.tag === "") return chain;
  const push = (value: Locale) => {
    if (!chain.includes(value.tag)) chain.push(value.tag);
  };
  const { language, region, script } = locale;
  const effective = effectiveScript(locale);
  const defaultMatches = effective === likelyScript(language);
  push(locale);
  push(compose(language, script, region));
  if (region) {
    if (!script && !defaultMatches) push(compose(language, effective, region));
    if (script && defaultMatches) push(compose(language, undefined, region));
  }
  if (!defaultMatches) {
    push(compose(language, effective));
    return chain;
  }
  if (script) push(compose(language, script));
  push(compose(language));
  return chain;
}

/**
 * The index in `available` of the best locale for the first requested one
 * that can use any: exact fallback matches first, then the same language
 * and script (en picks en-US, zh-HK picks zh-TW). -1 when none fits.
 */
export function negotiate(requested: readonly string[], available: readonly string[]): number {
  const have = available.map((tag) => parseLocale(tag));
  for (const text of requested) {
    let want: Locale;
    try {
      want = parseLocale(text);
    } catch {
      continue;
    }
    for (const candidate of fallbackChain(want)) {
      const index = have.findIndex((locale) => locale.tag === candidate);
      if (index !== -1) return index;
    }
    if (want.tag === "") continue;
    const index = have.findIndex((locale) => locale.language === want.language && effectiveScript(locale) === effectiveScript(want));
    if (index !== -1) return index;
  }
  return -1;
}

/** XA selects accented and XB bidi pseudolocalization. */
export function pseudoMode(tag: string | Locale): PseudoMode {
  const locale = typeof tag === "string" ? parseLocale(tag) : tag;
  return locale.region === "XA" ? "accented" : locale.region === "XB" ? "bidi" : "none";
}

// ---------------------------------------------------------------------------
// Messages

const accentedLower = "áƀçðéƒĝĥîĵķļɱñöþǫŕšţûṽŵẋýž";
const accentedUpper = "ÅƁÇÐÉƑĜĤÎĴĶĻṀÑÖÞǪŔŠŢÛṼŴẊÝŽ";
const accented = (text: string) =>
  text.replace(/[A-Za-z]/g, (c) => {
    const code = c.charCodeAt(0);
    return code >= 97 ? [...accentedLower][code - 97] : [...accentedUpper][code - 65];
  });

function utf8Length(text: string): number {
  let bytes = 0;
  for (const c of text) {
    const p = c.codePointAt(0)!;
    bytes += p < 0x80 ? 1 : p < 0x800 ? 2 : p < 0x10000 ? 3 : 4;
  }
  return bytes;
}

type Category = "zero" | "one" | "two" | "few" | "many" | "other";
const categories = new Set<string>(["zero", "one", "two", "few", "many", "other"]);

interface Context {
  intl: string;
  args: Arguments;
  mode: PseudoMode;
  isolate: boolean;
  out: string[];
}

interface Sign {
  value: number;
  offset: number;
}

const invalid = (): never => {
  throw new MessageError("InvalidMessage");
};

const formatters = new Map<string, Intl.NumberFormat | Intl.PluralRules | Intl.DateTimeFormat>();
function cached<T extends Intl.NumberFormat | Intl.PluralRules | Intl.DateTimeFormat>(key: string, make: () => T): T {
  let value = formatters.get(key) as T | undefined;
  if (!value) {
    value = make();
    formatters.set(key, value);
  }
  return value;
}

function numberFormat(locale: string, style: "decimal" | "integer" | "percent"): Intl.NumberFormat {
  return cached(`n:${locale}:${style}`, () =>
    new Intl.NumberFormat(locale, {
      style: style === "percent" ? "percent" : "decimal",
      maximumFractionDigits: style === "decimal" ? 3 : 0,
      // Ties round to even, as the Zig module rounds them.
      roundingMode: "halfEven",
    } as Intl.NumberFormatOptions),
  );
}

class Walker {
  position = 0;
  literalCodePoints = 0;
  constructor(
    readonly pattern: string,
    readonly context: Context | null,
  ) {}

  peek(): string | undefined {
    return this.position < this.pattern.length ? this.pattern[this.position] : undefined;
  }
  skipSpace(): void {
    for (let c = this.peek(); c === " " || c === "\t" || c === "\n" || c === "\r"; c = this.peek()) this.position++;
  }
  expect(c: string): void {
    if (this.peek() !== c) invalid();
    this.position++;
  }
  identifier(): string {
    const start = this.position;
    while (/[A-Za-z0-9_]/.test(this.peek() ?? "")) this.position++;
    if (this.position === start) invalid();
    return this.pattern.slice(start, this.position);
  }
  integer(): number {
    const start = this.position;
    if (this.peek() === "-") this.position++;
    while (/[0-9]/.test(this.peek() ?? "")) this.position++;
    const text = this.pattern.slice(start, this.position);
    if (!/^-?[0-9]+$/.test(text)) invalid();
    const value = BigInt(text);
    if (value > 9223372036854775807n || value < -9223372036854775808n) invalid();
    return Number(value);
  }
  text(emit: boolean, text: string): void {
    if (!emit) return;
    const context = this.context!;
    if (context.mode === "accented") context.out.push(accented(text));
    else if (context.mode === "bidi") {
      if (text.length) context.out.push("\u202E", text, "\u202C");
    } else context.out.push(text);
    this.literalCodePoints += [...text].length;
  }

  message(depth: number, sign: Sign | null, emit: boolean, nested: boolean): void {
    for (let c = this.peek(); c !== undefined; c = this.peek()) {
      if (c === "}") {
        if (nested) return;
        invalid();
      } else if (c === "{") {
        this.position++;
        this.argument(depth + 1, emit);
      } else if (c === "#") {
        this.position++;
        if (sign) {
          if (emit) this.context!.out.push(numberFormat(this.context!.intl, "decimal").format(sign.value - sign.offset));
        } else this.text(emit, "#");
      } else if (c === "'") this.apostrophe(emit, sign !== null);
      else {
        const start = this.position;
        for (let d = this.peek(); d !== undefined; d = this.peek()) {
          if (d === "{" || d === "}" || d === "'" || (d === "#" && sign)) break;
          this.position++;
        }
        this.text(emit, this.pattern.slice(start, this.position));
      }
    }
    if (nested) invalid();
  }

  apostrophe(emit: boolean, inPlural: boolean): void {
    const next = this.pattern[this.position + 1];
    if (next === "'") {
      this.position += 2;
      return this.text(emit, "'");
    }
    if (!(next === "{" || next === "}" || next === "|" || (next === "#" && inPlural))) {
      this.position++;
      return this.text(emit, "'");
    }
    this.position++;
    for (let c = this.peek(); c !== undefined; c = this.peek()) {
      if (c === "'") {
        if (this.pattern[this.position + 1] === "'") {
          this.position += 2;
          this.text(emit, "'");
          continue;
        }
        this.position++;
        return;
      }
      const start = this.position;
      while (this.peek() !== undefined && this.peek() !== "'") this.position++;
      this.text(emit, this.pattern.slice(start, this.position));
    }
  }

  find(name: string): Argument {
    const args = this.context!.args;
    if (!Object.hasOwn(args, name)) throw new MessageError("MissingArgument", `Missing argument: ${name}`);
    return args[name];
  }

  number(name: string): number {
    const value = this.find(name);
    if (typeof value === "bigint") return Number(value);
    if (typeof value !== "number") throw new MessageError("ArgumentType", `Argument ${name} is not a number`);
    return value;
  }

  argument(depth: number, emit: boolean): void {
    if (depth > maxDepth) throw new MessageError("NestingTooDeep");
    this.skipSpace();
    const name = this.identifier();
    this.skipSpace();
    if (this.peek() === "}") {
      this.position++;
      if (emit) this.simple(name);
      return;
    }
    this.expect(",");
    this.skipSpace();
    const kind = this.identifier();
    this.skipSpace();
    if (kind === "number") {
      const style = this.style();
      if (style !== null && style !== "integer" && style !== "percent") invalid();
      if (emit) this.context!.out.push(numberFormat(this.context!.intl, (style ?? "decimal") as "decimal").format(this.number(name)));
    } else if (kind === "date" || kind === "time") {
      const style = this.style() ?? "medium";
      if (!["short", "medium", "long", "full"].includes(style)) invalid();
      if (emit) {
        const value = this.find(name);
        if (!(value instanceof Date)) throw new MessageError("ArgumentType", `Argument ${name} is not a Date`);
        this.date(value, kind === "date" ? { dateStyle: style as "short" } : { timeStyle: style as "short" });
      }
    } else if (kind === "plural" || kind === "selectordinal") this.plural(name, depth, emit, kind === "selectordinal");
    else if (kind === "select") this.select(name, depth, emit);
    else invalid();
  }

  style(): string | null {
    if (this.peek() === "}") {
      this.position++;
      return null;
    }
    this.expect(",");
    this.skipSpace();
    const value = this.identifier();
    this.skipSpace();
    this.expect("}");
    return value;
  }

  simple(name: string): void {
    const context = this.context!;
    const value = this.find(name);
    if (typeof value === "string") {
      context.out.push(context.isolate ? `\u2068${value}\u2069` : value);
    } else if (value instanceof Date) {
      this.date(value, { dateStyle: "short", timeStyle: "short" });
    } else if (typeof value === "number" || typeof value === "bigint") {
      context.out.push(numberFormat(context.intl, "decimal").format(Number(value)));
    } else throw new MessageError("ArgumentType", `Argument ${name} has an unsupported type`);
  }

  date(value: Date, options: Intl.DateTimeFormatOptions): void {
    const time = value.getTime();
    if (!Number.isFinite(time) || value.getUTCFullYear() < 1 || value.getUTCFullYear() > 9999) throw new MessageError("OutOfRange");
    const key = `d:${this.context!.intl}:${options.dateStyle ?? ""}:${options.timeStyle ?? ""}`;
    this.context!.out.push(cached(key, () => new Intl.DateTimeFormat(this.context!.intl, options)).format(value));
  }

  plural(name: string, depth: number, emit: boolean, ordinal: boolean): void {
    this.expect(",");
    this.skipSpace();
    let offset = 0;
    if (this.pattern.startsWith("offset:", this.position)) {
      this.position += "offset:".length;
      this.skipSpace();
      offset = this.integer();
      this.skipSpace();
    }
    const value = emit ? this.number(name) : null;
    let selected: Category = "other";
    if (value !== null) {
      if (!Number.isFinite(value - offset)) throw new MessageError("OutOfRange");
      const rules = cached(`p:${this.context!.intl}:${ordinal}`, () => new Intl.PluralRules(this.context!.intl, { type: ordinal ? "ordinal" : "cardinal", maximumFractionDigits: 3 }));
      selected = rules.select(value - offset) as Category;
    }
    const sign: Sign = { value: value ?? 0, offset };
    const seen = new Set<string>();
    let exactStart: number | undefined;
    let keywordStart: number | undefined;
    let otherStart: number | undefined;
    while (this.peek() !== "}") {
      if (this.peek() === undefined) invalid();
      let exact: number | undefined;
      let category = "other";
      if (this.peek() === "=") {
        this.position++;
        exact = this.integer();
      } else {
        category = this.identifier();
        if (!categories.has(category) || seen.has(category)) invalid();
        seen.add(category);
      }
      this.skipSpace();
      this.expect("{");
      const start = this.position;
      this.message(depth, sign, false, true);
      this.expect("}");
      this.skipSpace();
      if (value !== null) {
        if (exact !== undefined) {
          if (exactStart === undefined && value === exact) exactStart = start;
        } else if (category === "other") otherStart = start;
        else if (category === selected && keywordStart === undefined) keywordStart = start;
      }
    }
    if (!seen.has("other")) invalid();
    const end = this.position + 1;
    if (emit) {
      this.position = exactStart ?? keywordStart ?? otherStart!;
      this.message(depth, sign, true, true);
    }
    this.position = end;
  }

  select(name: string, depth: number, emit: boolean): void {
    this.expect(",");
    this.skipSpace();
    const value = emit ? this.find(name) : null;
    if (value !== null && typeof value !== "string") throw new MessageError("ArgumentType", `Argument ${name} is not a string`);
    let matchStart: number | undefined;
    let otherStart: number | undefined;
    while (this.peek() !== "}") {
      if (this.peek() === undefined) invalid();
      const key = this.identifier();
      this.skipSpace();
      this.expect("{");
      const start = this.position;
      this.message(depth, null, false, true);
      this.expect("}");
      this.skipSpace();
      if (key === "other") {
        if (otherStart !== undefined) invalid();
        otherStart = start;
      } else if (value !== null && matchStart === undefined && key === value) matchStart = start;
    }
    if (otherStart === undefined) invalid();
    const end = this.position + 1;
    if (emit) {
      this.position = matchStart ?? otherStart!;
      this.message(depth, null, true, true);
    }
    this.position = end;
  }
}

/** Throws a {@link MessageError} when the message does not parse. */
export function validateMessage(pattern: string): void {
  if (utf8Length(pattern) > maxPatternBytes) invalid();
  new Walker(pattern, null).message(0, null, false, false);
}

/**
 * Formats a message for a locale. Syntax errors throw before anything is
 * formatted; missing arguments and arguments of the wrong type throw too.
 */
export function formatMessage(locale: string, pattern: string, args: Arguments = {}, options: FormatOptions = {}): string {
  validateMessage(pattern);
  const parsed = parseLocale(locale);
  const mode = options.pseudo ?? "none";
  const context: Context = {
    intl: parsed.tag === "" ? "en" : parsed.tag,
    args,
    mode,
    isolate: (options.isolateArguments ?? true) && direction(parsed) === "rtl",
    out: [],
  };
  const walker = new Walker(pattern, context);
  if (mode === "accented") context.out.push("[");
  else if (mode === "bidi") context.out.push("\u200F");
  walker.message(0, null, true, false);
  if (mode === "accented") context.out.push(" ", "~".repeat(Math.max(1, Math.floor((walker.literalCodePoints * 2 + 4) / 5))), "]");
  else if (mode === "bidi") context.out.push("\u200F");
  return context.out.join("");
}

// ---------------------------------------------------------------------------
// Catalogs

/** Messages by locale; nested objects flatten with "." as the Zig catalog's JSON does. */
export interface CatalogData {
  /** The locale the app is written in; its messages back every other locale. */
  source: string;
  messages: Readonly<Record<string, MessageTree>>;
  /**
   * Argument names by key, in the order the functions of `messages()` take
   * them; keys without an entry take one object of named arguments.
   */
  params?: Readonly<Record<string, readonly string[]>>;
}

/** One function per message key, formatting in the current or given locale. */
export type MessageFunctions = Record<string, (...args: Argument[] | [Arguments?]) => string>;
export interface MessageTree {
  readonly [key: string]: string | MessageTree;
}

export interface Localizer {
  /** The display locale. */
  readonly locale: string;
  readonly direction: Direction;
  has(key: string): boolean;
  /** The formatted message; a missing key formats as the key itself. */
  format(key: string, args?: Arguments): string;
}

export interface Catalog {
  readonly source: string;
  /** The locales with messages, as canonical tags. */
  readonly locales: readonly string[];
  /** The best available locale for the user's preferences, else the source. */
  negotiate(requested: readonly string[]): string;
  localizer(locale: string, options?: FormatOptions): Localizer;
  /**
   * Functions for every key in the page's current language: the connected
   * runtime's locale (followed as it changes), otherwise the browser's
   * preferred languages, negotiated against the catalog's.
   */
  messages<M = MessageFunctions>(): M;
  /** Functions for every key in one negotiated locale. */
  messagesIn<M = MessageFunctions>(locale: string): M;
}

/** The page's language: the connected runtime's, else the browser's first. */
export function currentLocale(): string {
  const shared = (globalThis as unknown as Record<symbol, { connection?: { runtime: { locale: string } } } | undefined>)[Symbol.for("ziggurat.runtime")];
  const tag = shared?.connection?.runtime.locale;
  if (tag) return tag;
  const languages = (globalThis as { navigator?: { languages?: readonly string[]; language?: string } }).navigator;
  return languages?.languages?.[0] ?? languages?.language ?? "en";
}

function flatten(tree: MessageTree, prefix: string, into: Map<string, string>, depth: number, locale: string): void {
  if (depth > 8) throw new MessageError("InvalidMessage", `Messages of ${locale} nest too deeply`);
  for (const [name, value] of Object.entries(tree)) {
    const key = prefix ? `${prefix}.${name}` : name;
    if (typeof value === "string") {
      if (!key || utf8Length(key) > 256 || /[\u0000-\u001f\u007f]/.test(key) || into.has(key)) {
        throw new MessageError("InvalidMessage", `Invalid or duplicate key in ${locale}: ${key}`);
      }
      try {
        validateMessage(value);
      } catch (error) {
        throw new MessageError((error as MessageError).code, `Invalid message ${key} in ${locale}`);
      }
      into.set(key, value);
    } else if (typeof value === "object" && value !== null && !Array.isArray(value)) {
      flatten(value, key, into, depth + 1, locale);
    } else throw new MessageError("InvalidMessage", `Message ${key} in ${locale} is not a string`);
  }
}

/** Validates every message up front; an invalid one throws naming its key. */
export function createCatalog(data: CatalogData): Catalog {
  const bundles = new Map<string, Map<string, string>>();
  for (const [tag, tree] of Object.entries(data.messages)) {
    const locale = parseLocale(tag).tag;
    if (bundles.has(locale)) throw new MessageError("InvalidLocale", `Duplicate locale: ${tag}`);
    const messages = new Map<string, string>();
    flatten(tree, "", messages, 1, tag);
    bundles.set(locale, messages);
  }
  const source = parseLocale(data.source).tag;
  const locales = Object.freeze([...bundles.keys()]);
  const keys = [...new Set([...bundles.values()].flatMap((messages) => [...messages.keys()]))];
  const functions = (localize: () => Localizer) => {
    const result: Record<string, (...args: unknown[]) => string> = Object.create(null);
    for (const key of keys) {
      const names = data.params?.[key];
      result[key] = (...args: unknown[]) => {
        const named = names ? Object.fromEntries(names.map((name, index) => [name, args[index]])) : args[0];
        return localize().format(key, (named ?? {}) as Arguments);
      };
    }
    return result;
  };
  let current: { tag: string; localizer: Localizer } | undefined;
  const catalog: Catalog = {
    source,
    locales,
    negotiate(requested) {
      const index = negotiate(requested, locales);
      return index === -1 ? source : locales[index];
    },
    messages<M>() {
      return functions(() => {
        const tag = currentLocale();
        if (current?.tag !== tag) current = { tag, localizer: catalog.localizer(pseudoMode(safeLocale(tag)) === "none" ? catalog.negotiate([tag]) : tag) };
        return current.localizer;
      }) as M;
    },
    messagesIn<M>(tag: string) {
      const localizer = catalog.localizer(pseudoMode(safeLocale(tag)) === "none" ? catalog.negotiate([tag]) : tag);
      return functions(() => localizer) as M;
    },
    localizer(tag, options = {}) {
      const display = parseLocale(tag);
      const mode = options.pseudo ?? pseudoMode(display);
      // Pseudolocales render the source messages, unless they have their own.
      const own = mode === "none" || bundles.has(display.tag) ? fallbackChain(display).filter((t) => bundles.has(t)) : [];
      const chain = [...own];
      for (const t of fallbackChain(source)) if (bundles.has(t) && !chain.includes(t)) chain.push(t);
      const resolve = (key: string): { pattern: string; locale: string } | undefined => {
        for (const [index, t] of chain.entries()) {
          const pattern = bundles.get(t)!.get(key);
          // Own-chain messages format in the display locale (de-CH digits for
          // a de message); source fallbacks keep the source's conventions.
          if (pattern !== undefined) return { pattern, locale: index < own.length ? display.tag : t };
        }
        return undefined;
      };
      return {
        locale: display.tag,
        direction: mode === "bidi" ? "rtl" : direction(display),
        has: (key) => resolve(key) !== undefined,
        format(key, args = {}) {
          const found = resolve(key);
          if (!found) return key;
          return formatMessage(found.locale, found.pattern, args, { pseudo: mode, isolateArguments: options.isolateArguments });
        },
      };
    },
  };
  return catalog;
}

function safeLocale(tag: string): Locale {
  try {
    return parseLocale(tag);
  } catch {
    return root;
  }
}
