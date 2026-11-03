// Drives the browser smoke app (tests/web/smoke_app.zig) in the page and
// reports PASS or the first failure to the server that serves it
// (tests/web/smoke.py).
(async () => {
  const result = document.getElementById("result");
  let reported = false;
  const report = (text) => {
    if (reported) return;
    reported = true;
    result.textContent = text;
    fetch("/result", { method: "POST", body: text });
  };
  const fail = (message) => {
    report("FAIL: " + message);
    throw new Error(message);
  };
  const frames = (n) => new Promise((done) => {
    const step = () => (n-- <= 0 ? done() : requestAnimationFrame(step));
    requestAnimationFrame(step);
  });
  const until = async (what, test) => {
    for (let i = 0; i < 200; i++) {
      if (test()) return;
      await frames(1);
    }
    fail("timed out waiting for " + what);
  };
  // Pixels near a color in the window's canvas.
  const count = (rgb) => {
    const canvas = document.querySelector(".ziggurat-window canvas");
    const data = canvas.getContext("2d", { willReadFrequently: true }).getImageData(0, 0, canvas.width, canvas.height).data;
    const r = rgb >> 16, g = (rgb >> 8) & 255, b = rgb & 255;
    let n = 0;
    for (let i = 0; i < data.length; i += 4) if (Math.abs(data[i] - r) < 24 && Math.abs(data[i + 1] - g) < 24 && Math.abs(data[i + 2] - b) < 24) n++;
    return n;
  };
  const click = (x, y) => {
    const canvas = document.querySelector(".ziggurat-window canvas");
    const box = canvas.getBoundingClientRect();
    const init = { bubbles: true, cancelable: true, clientX: box.left + x, clientY: box.top + y, button: 0, buttons: 1, pointerId: 1, pointerType: "mouse", isPrimary: true };
    canvas.dispatchEvent(new PointerEvent("pointermove", init));
    canvas.dispatchEvent(new PointerEvent("pointerdown", init));
    canvas.dispatchEvent(new PointerEvent("pointerup", { ...init, buttons: 0 }));
  };
  const blue = 0x276aa5, orange = 0xa8530f;
  try {
    window.addEventListener("error", (e) => fail("page error: " + e.message));
    const started = await Ziggurat.run("app.wasm");
    if (!started.running) fail("the app exited: " + JSON.stringify(started));
    await until("the first frame", () => document.querySelector(".ziggurat-window canvas") && count(blue) > 20);
    if (document.title !== "Ziggurat smoke") fail("page title " + document.title);
    await until("the router to claim the fragment", () => location.hash === "#/");
    click(148, 44);
    await until("the About page", () => location.hash === "#/about" && count(orange) > 20 && count(blue) < 20);
    history.back();
    await until("Back to the home page", () => location.hash === "#/" && count(blue) > 20 && count(orange) < 20);
    history.forward();
    await until("Forward to the About page", () => location.hash === "#/about" && count(orange) > 20);
    // A secondary press opens the context menu of HTML; its choice reaches
    // the app, which shows it in the title.
    const canvas = document.querySelector(".ziggurat-window canvas");
    const box = canvas.getBoundingClientRect();
    const press = { bubbles: true, cancelable: true, clientX: box.left + 200, clientY: box.top + 120, button: 2, buttons: 2, pointerId: 1, pointerType: "mouse", isPrimary: true };
    canvas.dispatchEvent(new PointerEvent("pointermove", { ...press, button: -1, buttons: 0 }));
    canvas.dispatchEvent(new PointerEvent("pointerdown", press));
    canvas.dispatchEvent(new PointerEvent("pointerup", { ...press, buttons: 0 }));
    await until("the context menu", () => document.querySelector(".ziggurat-menu"));
    const labels = Array.from(document.querySelectorAll(".ziggurat-menu > li[role=menuitem]")).map((li) => li.textContent);
    if (labels.join("|") !== "Add ten|Reset") fail("menu items " + labels.join("|"));
    await frames(2);
    document.querySelector(".ziggurat-menu > li[role=menuitem]").click();
    await until("the menu's choice", () => document.title === "Menu: Add ten" && !document.querySelector(".ziggurat-menu"));
    report("PASS");
  } catch (err) {
    report("FAIL: " + (err && err.stack ? err.stack : err));
  }
})();
