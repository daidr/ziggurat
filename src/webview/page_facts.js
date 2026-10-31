// Facts a page tells its View without the page's own code: its theme color
// and the size of its content. The backends call this function at document
// start in the top frame with a post function that reaches the View alone,
// and the options the View asked for. Messages are one letter and a value:
// T#rrggbbaa (T alone: none), S<width>,<height>,<scrollbar>,<horizontal>.
(post, options) => {
  if (window !== top) return;
  const hex2 = (n) => Math.round(Math.min(Math.max(n, 0), 255)).toString(16).padStart(2, "0");
  const ready = (fn) => {
    if (document.readyState === "loading") addEventListener("DOMContentLoaded", fn, { once: true });
    else fn();
  };

  if (options.theme) {
    let ctx;
    const fillStyleHex = (s) => {
      if (/^#[0-9a-f]{6}$/i.test(s)) return s.toLowerCase() + "ff";
      const m = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:[\s,/]+([\d.]+))?\s*\)$/i.exec(s);
      if (!m) return null;
      return "#" + hex2(+m[1]) + hex2(+m[2]) + hex2(+m[3]) + hex2(m[4] === undefined ? 255 : +m[4] * 255);
    };
    // The engine parses the color: a canvas's fillStyle keeps its value when
    // given something else than a color, and colors it does not serialize as
    // sRGB are drawn and read back.
    const parse = (value) => {
      value = value.trim();
      if (!value) return null;
      if (ctx === undefined) {
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = 1;
        ctx = canvas.getContext("2d", { willReadFrequently: true });
      }
      if (!ctx) return null;
      ctx.fillStyle = "#000";
      ctx.fillStyle = value;
      if (ctx.fillStyle === "#000000") {
        ctx.fillStyle = "#fff";
        ctx.fillStyle = value;
        if (ctx.fillStyle === "#ffffff") return null;
      }
      const hex = fillStyleHex(String(ctx.fillStyle));
      if (hex) return hex;
      ctx.clearRect(0, 0, 1, 1);
      ctx.fillRect(0, 0, 1, 1);
      const d = ctx.getImageData(0, 0, 1, 1).data;
      return "#" + hex2(d[0]) + hex2(d[1]) + hex2(d[2]) + hex2(d[3]);
    };
    const queries = new Map();
    const matches = (media) => {
      let q = queries.get(media);
      if (!q) {
        q = matchMedia(media);
        if (q.addEventListener) q.addEventListener("change", update);
        else q.addListener(update);
        queries.set(media, q);
      }
      return q.matches;
    };
    // The first meta of the head whose media is absent or matches and whose
    // content is a color, as browsers pick it.
    const current = () => {
      if (!document.head) return null;
      for (const m of document.head.querySelectorAll('meta[name="theme-color" i]')) {
        const media = (m.getAttribute("media") || "").trim();
        if (media && !matches(media)) continue;
        const c = parse(m.getAttribute("content") || "");
        if (c !== null) return c;
      }
      return null;
    };
    // Before the DOM is ready only a color is told, so that going between
    // pages of the same color tells nothing; once it is ready, none too.
    let last, loaded = false;
    const report = (c) => {
      if (c === last || (c === null && last === undefined && !loaded)) return;
      last = c;
      post("T" + (c || ""));
    };
    function update() { report(current()); }
    const isMeta = (n) => n.localName === "meta";
    const hasMeta = (nodes) => {
      for (const n of nodes) if (n.nodeType === 1 && (isMeta(n) || n.querySelector("meta"))) return true;
      return false;
    };
    let head = null, root = null;
    // The head only, so that pages changing their body pay nothing; the
    // document and its root for a head that comes, or is replaced, later.
    const observer = new MutationObserver((records) => {
      let changed = false;
      for (const r of records) {
        if (r.target === document || r.target === document.documentElement) { observe(); changed = true; }
        else if (r.type === "attributes") changed ||= isMeta(r.target);
        else changed ||= hasMeta(r.addedNodes) || hasMeta(r.removedNodes);
      }
      if (changed) update();
    });
    function observe() {
      if (document.documentElement !== root && (root = document.documentElement)) observer.observe(root, { childList: true });
      if (document.head !== head && (head = document.head))
        observer.observe(head, { childList: true, subtree: true, attributes: true, attributeFilter: ["name", "content", "media"] });
    }
    observer.observe(document, { childList: true });
    observe();
    update();
    ready(() => { loaded = true; report(current()); });
  }

  const limits = options.fit;
  if (limits) {
    // The root is laid out at its content's width within the limits, so that
    // text wraps at the maximum width, and its height is its content's. The
    // rule has no specificity, so a page's own size for html wins.
    let scrollbar = 0, pending = false, started = false, last = "";
    let sheet = null, style = null;
    const rule = () => {
      const d = ["width:max-content"];
      if (limits.minWidth > 0) d.push(`min-width:${Math.max(limits.minWidth - scrollbar, 0)}px`);
      if (limits.maxWidth > 0) d.push(`max-width:${Math.max(limits.maxWidth - scrollbar, 0)}px`);
      if (limits.minHeight > 0) d.push(`min-height:${limits.minHeight}px`);
      return `:where(:root){${d.join(";")}}`;
    };
    const apply = () => {
      const text = rule();
      try {
        if (!sheet) {
          sheet = new CSSStyleSheet();
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        }
        sheet.replaceSync(text);
        return;
      } catch {}
      if (!style) {
        style = document.createElement("style");
        (document.head || document.documentElement).appendChild(style);
      }
      style.textContent = text;
    };
    // Changing the root's size in a ResizeObserver's callback would end its
    // loop with an error the page would hear: the rule changes in the next
    // frame then, and the observer tells the size.
    const measure = (fromObserver) => {
      const root = document.documentElement;
      if (!root) return;
      const viewport = document.scrollingElement || root;
      const sw = Math.max(innerWidth - viewport.clientWidth, 0);
      const sh = Math.max(innerHeight - viewport.clientHeight, 0);
      let r = root.getBoundingClientRect();
      // A vertical scrollbar shows for a moment whenever the content grows
      // before the window does: its room is left out of the width only where
      // the content is taller than the window may be.
      const room = limits.maxHeight > 0 && r.height > limits.maxHeight ? sw : 0;
      if (room !== scrollbar) {
        scrollbar = room;
        if (!fromObserver) { apply(); r = root.getBoundingClientRect(); }
        else if (!pending) { pending = true; requestAnimationFrame(() => { pending = false; apply(); }); }
      }
      const body = document.body;
      const wider = !!body && body.scrollWidth > body.clientWidth;
      const size = [r.width, r.height, sw, wider ? sh : 0].map((v) => Math.round(v * 64) / 64).join(",");
      if (size === last) return;
      last = size;
      post("S" + size);
    };
    const start = () => {
      if (started) return;
      started = true;
      apply();
      measure(false);
      if (typeof ResizeObserver !== "undefined") new ResizeObserver(() => measure(true)).observe(document.documentElement);
      addEventListener("resize", () => measure(false));
    };
    if (document.documentElement) apply();
    ready(start);
  }
}
