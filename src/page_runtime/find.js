(() => {
  if (window.__zigguratFind) return;
  // Highlights page text without moving focus or the selection. The custom
  // highlight registry leaves the DOM untouched; elsewhere matches are
  // wrapped in <mark> elements that stop() unwraps again.
  const skipped = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "TEXTAREA", "INPUT", "SELECT", "OPTION", "IFRAME", "OBJECT"]);
  const highlights = () => (typeof CSS !== "undefined" && CSS.highlights && typeof Highlight === "function" ? CSS.highlights : null);
  const initial = () => ({ text: "", matchCase: false, ranges: [], active: -1, marks: [], style: null, registry: null });
  let state = initial();

  // Offsets of every occurrence of needle in text, without overlaps.
  const search = (text, needle, matchCase) => {
    const result = [];
    if (needle.length === 0) return { offsets: result, length: 0 };
    const haystack = matchCase ? text : text.toLowerCase();
    const wanted = matchCase ? needle : needle.toLowerCase();
    // Lower-casing can change lengths; search the original then.
    const exact = haystack.length === text.length && wanted.length === needle.length;
    const source = exact ? haystack : text;
    const target = exact ? wanted : needle;
    for (let at = source.indexOf(target); at !== -1; at = source.indexOf(target, at + target.length)) result.push(at);
    return { offsets: result, length: target.length };
  };

  const visible = (element) => {
    for (let node = element; node; node = node.parentElement) {
      if (skipped.has(node.tagName) || node.hidden) return false;
    }
    if (typeof element.checkVisibility === "function") return element.checkVisibility();
    return element.getClientRects().length > 0;
  };

  const collect = (text, matchCase) => {
    const ranges = [];
    const root = document.body || document.documentElement;
    if (!root) return ranges;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const parent = node.parentElement;
      if (!parent || !node.data || !visible(parent)) continue;
      const found = search(node.data, text, matchCase);
      for (const offset of found.offsets) {
        const range = document.createRange();
        range.setStart(node, offset);
        range.setEnd(node, offset + found.length);
        ranges.push(range);
      }
    }
    return ranges;
  };

  const ensureStyle = () => {
    if (state.style || !document.head) return;
    const style = document.createElement("style");
    style.textContent =
      "::highlight(ziggurat-find){background:#fde68a;color:inherit}" +
      "::highlight(ziggurat-find-active){background:#f59e0b;color:inherit}" +
      "mark[data-ziggurat-find]{background:#fde68a;color:inherit}" +
      "mark[data-ziggurat-find=active]{background:#f59e0b}";
    document.head.appendChild(style);
    state.style = style;
  };

  const unmark = () => {
    for (const mark of state.marks) {
      const parent = mark.parentNode;
      if (!parent) continue;
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
      parent.removeChild(mark);
      parent.normalize();
    }
    state.marks = [];
  };

  const paint = () => {
    ensureStyle();
    const registry = state.registry;
    if (registry) {
      registry.set("ziggurat-find", new Highlight(...state.ranges));
      const active = state.ranges[state.active];
      if (active) registry.set("ziggurat-find-active", new Highlight(active));
      else registry.delete("ziggurat-find-active");
      return;
    }
    if (state.marks.length > 0) {
      state.marks.forEach((mark, i) => mark.setAttribute("data-ziggurat-find", i === state.active ? "active" : ""));
      return;
    }
    // Wrap from the end so earlier ranges in the same node keep their offsets.
    const marks = new Array(state.ranges.length);
    for (let i = state.ranges.length - 1; i >= 0; i--) {
      const mark = document.createElement("mark");
      mark.setAttribute("data-ziggurat-find", i === state.active ? "active" : "");
      state.ranges[i].surroundContents(mark);
      marks[i] = mark;
    }
    state.marks = marks;
  };

  const reveal = () => {
    const mark = state.marks[state.active];
    const range = state.ranges[state.active];
    const element = mark || (range && range.startContainer.parentElement);
    if (element && element.scrollIntoView) element.scrollIntoView({ block: "center", inline: "nearest" });
  };

  const stop = () => {
    if (state.registry) {
      state.registry.delete("ziggurat-find");
      state.registry.delete("ziggurat-find-active");
    }
    unmark();
    if (state.style) state.style.remove();
    state = initial();
  };

  const find = (text, options) => {
    const matchCase = !!options.matchCase;
    const again = options.findNext && text === state.text && matchCase === state.matchCase && state.ranges.length > 0;
    if (!again) {
      stop();
      if (text.length === 0) return { matches: 0, active: 0 };
      state.text = text;
      state.matchCase = matchCase;
      state.registry = highlights();
      state.ranges = collect(text, matchCase);
      if (state.ranges.length === 0) return { matches: 0, active: 0 };
      state.active = options.backward ? state.ranges.length - 1 : 0;
    } else {
      const count = state.ranges.length;
      state.active = (state.active + (options.backward ? count - 1 : 1)) % count;
    }
    paint();
    reveal();
    return { matches: state.ranges.length, active: state.active + 1 };
  };

  Object.defineProperty(window, "__zigguratFind", { value: Object.freeze({ find, stop, search }) });
})();
