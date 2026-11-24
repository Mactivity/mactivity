// mactivity.app: the interactive demos. Everything is simulated; a web page can't read your Mac.
// No libraries, no cookies, no storage, no network. Without JavaScript the page still reads fine.
(() => {
  "use strict";
  document.documentElement.classList.add("js");
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  // The app's real icon where the site has one (as in the live demo), its letter otherwise.
  const APP_ICONS = { Xcode: "xcode", Safari: "safari", macOS: "macos", Terminal: "terminal", Code: "code", Music: "music",
    Finder: "finder", FaceTime: "facetime", Podcasts: "podcasts" };
  const appBadge = (app) => {
    const slug = APP_ICONS[app.name];
    if (!slug) {
      const letter = el("i", "badge", app.name[0]);
      letter.style.background = app.color;
      return letter;
    }
    const img = el("img", "badge app-icon");
    img.src = `/icons/apps/${slug}.png`;
    img.alt = "";
    img.width = img.height = 32;
    return img;
  };

  // MARK: Simulated Mac

  const mac = {
    cpu: 18, memUsed: 22.4, memTotal: 36, down: 1.2e6, up: 1.1e5, gpu: 9, temp: 54, battery: 84, diskFree: 412,
    history: { cpu: [], memory: [], network: [], gpu: [], temp: [], battery: [] },
  };
  const walk = (value, step, min, max) => Math.min(max, Math.max(min, value + (Math.random() - 0.5) * 2 * step));
  const bytes = (bps) => (bps >= 1e6 ? `${(bps / 1e6).toFixed(1)} MB/s` : `${Math.round(bps / 1e3)} kB/s`);
  const metrics = {
    cpu: { label: "CPU", short: "CPU", value: () => `${Math.round(mac.cpu)}%`, level: () => mac.cpu / 100 },
    memory: {
      label: "Memory", short: "MEM", value: () => `${Math.round((mac.memUsed / mac.memTotal) * 100)}%`,
      level: () => mac.memUsed / mac.memTotal,
    },
    network: { label: "Network", short: "NET", value: () => bytes(mac.down), level: () => Math.min(1, mac.down / 4e6) },
    gpu: { label: "GPU", short: "GPU", value: () => `${Math.round(mac.gpu)}%`, level: () => mac.gpu / 100 },
    temp: { label: "Temperature", short: "TEMP", value: () => `${Math.round(mac.temp)}°`, level: () => (mac.temp - 30) / 70 },
    battery: { label: "Battery", short: "BAT", value: () => `${Math.round(mac.battery)}%`, level: () => mac.battery / 100 },
  };
  const apps = [
    { name: "Xcode", color: "#2f7bff", cpu: 6.1 },
    { name: "Safari", color: "#1aa7ff", cpu: 4.2 },
    { name: "macOS", color: "#8e8e93", cpu: 3.9 },
    { name: "Terminal", color: "#3a3a3c", cpu: 2.7 },
    { name: "Code", color: "#0f7fd1", cpu: 1.8 },
    { name: "Music", color: "#ff375f", cpu: 0.6 },
  ];
  const tickListeners = [];
  function tick() {
    mac.cpu = walk(mac.cpu, 7, 4, 78);
    mac.memUsed = walk(mac.memUsed, 0.35, 18, 30);
    mac.down = walk(mac.down, 5e5, 2e4, 4e6);
    mac.up = walk(mac.up, 4e4, 2e3, 6e5);
    mac.gpu = walk(mac.gpu, 5, 1, 60);
    mac.temp = walk(mac.temp, 1.5, 44, 78);
    for (const app of apps) app.cpu = walk(app.cpu, 0.8, 0.1, 14);
    for (const [key, metric] of Object.entries(metrics)) {
      const series = mac.history[key];
      series.push(metric.level());
      if (series.length > 14) series.shift();
    }
    tickListeners.forEach((listener) => listener());
  }
  for (let i = 0; i < 14; i += 1) tick();

  // MARK: Menu bar playground

  const pulseSVG = () => {
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 20 14");
    svg.setAttribute("class", "pulse");
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS(ns, "path");
    path.setAttribute("d", "M1 8h4l2-5 3 9 2.5-6 1.5 2H19");
    svg.append(path);
    return svg;
  };

  function menuBarDemo(root) {
    const item = $(".mbd-item", root);
    const panel = $(".mbd-window", root);
    const metricBar = $("[data-metrics]", root);
    const state = { mode: "stacked", metric: "cpu", stacked: ["cpu", "memory"] };

    function renderItem() {
      item.replaceChildren();
      if (state.mode === "icon") {
        item.append(pulseSVG());
      } else if (state.mode === "figure") {
        item.append(pulseSVG(), el("span", "fig", metrics[state.metric].value()));
      } else if (state.mode === "graph") {
        const bars = el("span", "bars");
        for (const level of mac.history[state.metric]) {
          const bar = el("i");
          bar.style.height = `${Math.max(8, Math.round(level * 100))}%`;
          bars.append(bar);
        }
        item.append(bars, el("span", "fig", metrics[state.metric].value()));
      } else {
        item.append(pulseSVG());
        for (const key of state.stacked) {
          const col = el("span", "col");
          col.append(el("small", "", metrics[key].short), el("b", "", metrics[key].value()));
          item.append(col);
        }
      }
    }

    function renderMetricButtons() {
      $$("button", metricBar).forEach((button) => {
        const key = button.dataset.metric;
        const on = state.mode === "stacked" ? state.stacked.includes(key) : state.metric === key;
        button.setAttribute("aria-pressed", String(on));
        button.disabled = state.mode === "icon";
      });
      $(".mbd-hint", root).textContent =
        state.mode === "icon" ? "The lightest display. It turns into a warning sign when your Mac is under strain."
        : state.mode === "stacked" ? "Pick up to four. Each column is a label over its value."
        : "Pick the metric it shows.";
    }

    $$("[data-mode]", root).forEach((button) => {
      button.addEventListener("click", () => {
        state.mode = button.dataset.mode;
        $$("[data-mode]", root).forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
        renderMetricButtons();
        renderItem();
      });
    });
    $$("button", metricBar).forEach((button) => {
      button.addEventListener("click", () => {
        const key = button.dataset.metric;
        if (state.mode === "stacked") {
          const at = state.stacked.indexOf(key);
          if (at >= 0 && state.stacked.length > 1) state.stacked.splice(at, 1);
          else if (at < 0 && state.stacked.length < 4) state.stacked.push(key);
        } else {
          state.metric = key;
        }
        renderMetricButtons();
        renderItem();
      });
    });

    // The menu bar window.
    const rows = $(".mbd-rows", panel);
    const busy = $(".mbd-busy", panel);
    function renderPanel() {
      if (panel.hidden) return;
      const lines = [
        ["Uptime", "9d 4h"],
        ["CPU", metrics.cpu.value()],
        ["GPU", metrics.gpu.value()],
        ["Memory", `${mac.memUsed.toFixed(0)} GB of ${mac.memTotal} GB`],
        ["Disk", `${mac.diskFree} GB free`],
        ["Network", `${bytes(mac.down)} ↓ · ${bytes(mac.up)} ↑`],
        ["Battery", `${Math.round(mac.battery)}% · 5h 29m`],
        ["Temperature", metrics.temp.value()],
      ];
      rows.replaceChildren(...lines.map(([name, value]) => {
        const row = el("div", "row");
        row.append(el("span", "", name), el("b", "", value));
        return row;
      }));
      const top = [...apps].sort((a, b) => b.cpu - a.cpu).slice(0, 3);
      busy.replaceChildren(...top.map((app) => {
        const row = el("div", "row");
        const name = el("span", "app");
        const badge = appBadge(app);
        name.append(badge, document.createTextNode(app.name));
        row.append(name, el("b", "", `${app.cpu.toFixed(0)}%`));
        return row;
      }));
    }
    function setOpen(open) {
      panel.hidden = !open;
      item.setAttribute("aria-expanded", String(open));
      renderPanel();
    }
    item.addEventListener("click", (event) => {
      event.stopPropagation();
      setOpen(panel.hidden);
    });
    panel.addEventListener("click", (event) => event.stopPropagation());
    document.addEventListener("click", () => setOpen(false));
    document.addEventListener("keydown", (event) => { if (event.key === "Escape") setOpen(false); });
    $$(".mbd-footer button", panel).forEach((button) => button.addEventListener("click", () => setOpen(false)));

    tickListeners.push(() => { if (state.mode !== "icon") renderItem(); renderPanel(); });
    // Starts open, so the window is the first thing you see; click anywhere else to close it.
    renderMetricButtons();
    renderItem();
    renderPanel();
  }

  // MARK: Who's using your Mac? (a metric switcher over apps with their processes folded in)

  const roster = [
    { name: "Xcode", color: "#2f7bff", cpu: 6.1, gpu: 2.2, memory: 3.1, network: 0.02, energy: 102,
      procs: [["Xcode", 0.46], ["SourceKitService", 0.27], ["swift-frontend", 0.17], ["XCBBuildService", 0.1]] },
    { name: "Safari", color: "#1aa7ff", cpu: 4.2, gpu: 3.1, memory: 2.0, network: 1.1, energy: 59,
      procs: [["Safari Web Content", 0.41], ["Safari Web Content", 0.24], ["Safari", 0.2], ["Safari Networking", 0.15]] },
    { name: "macOS", color: "#8e8e93", cpu: 3.9, gpu: 1.2, memory: 2.5, network: 0.05, energy: 71,
      procs: [["kernel_task", 0.48], ["WindowServer", 0.32], ["mds_stores", 0.14], ["launchd", 0.06]] },
    { name: "Terminal", color: "#48484a", cpu: 2.7, gpu: 0.1, memory: 0.9, network: 0.06, energy: 43,
      procs: [["node", 0.44], ["node", 0.3], ["python3", 0.16], ["zsh", 0.06], ["Terminal", 0.04]] },
    { name: "Code", color: "#0f7fd1", cpu: 1.8, gpu: 0.9, memory: 1.0, network: 0.01, energy: 31,
      procs: [["Code Helper (Renderer)", 0.48], ["Code Helper (Plugin)", 0.3], ["Code Helper (GPU)", 0.14], ["Code", 0.08]] },
    { name: "Music", color: "#ff375f", cpu: 0.6, gpu: 0.4, memory: 0.5, network: 0.04, energy: 12,
      procs: [["Music", 0.7], ["AMPLibraryAgent", 0.22], ["AMPArtworkAgent", 0.08]] },
  ];
  const switcherMetrics = {
    cpu: { color: "var(--cpu)", format: (v) => `${v < 1 ? v.toFixed(1) : Math.round(v)}%`, step: 0.8, max: 14 },
    gpu: { color: "var(--gpu)", format: (v) => `${v < 1 ? v.toFixed(1) : Math.round(v)}%`, step: 0.5, max: 9 },
    memory: { color: "var(--memory)", format: (v) => (v >= 1 ? `${v.toFixed(1)} GB` : `${Math.round(v * 1000)} MB`), step: 0.03, max: 4 },
    network: { color: "var(--network)", format: (v) => (v >= 1 ? `${v.toFixed(1)} MB/s` : `${Math.round(v * 1000)} kB/s`), step: 0.08, max: 1.6 },
    energy: { color: "var(--battery)", format: (v) => v.toFixed(1), step: 3, max: 140 },
  };

  function switcherDemo(root) {
    const list = $(".ms-list", root);
    const open = new Set();
    let metric = "cpu";
    function render() {
      const spec = switcherMetrics[metric];
      const ranked = [...roster].sort((a, b) => b[metric] - a[metric]);
      const top = ranked[0][metric] || 1;
      list.replaceChildren(...ranked.map((app) => {
        const details = el("details", "ms-app");
        details.open = open.has(app.name);
        details.addEventListener("toggle", () => { if (details.open) open.add(app.name); else open.delete(app.name); });
        const summary = el("summary", "ms-row");
        const badge = appBadge(app);
        const name = el("span", "name");
        name.append(badge, document.createTextNode(app.name));
        const meter = el("span", "ms-meter");
        const fill = el("i");
        fill.style.width = `${Math.max(2, (app[metric] / top) * 100)}%`;
        fill.style.background = spec.color;
        meter.append(fill);
        summary.append(name, meter, el("b", "", spec.format(app[metric])));
        details.append(summary);
        for (const [proc, share] of app.procs) {
          const row = el("div", "ms-proc");
          row.append(el("span", "", proc), el("b", "", spec.format(app[metric] * share)));
          details.append(row);
        }
        return details;
      }));
    }
    $$("[data-metric]", root).forEach((button) => {
      button.addEventListener("click", () => {
        metric = button.dataset.metric;
        $$("[data-metric]", root).forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
        render();
      });
    });
    // Live figures. The list holds still under the pointer, so a row never moves as you click it,
    // and catches up when the pointer leaves.
    let hovering = false;
    root.addEventListener("pointerenter", () => { hovering = true; });
    root.addEventListener("pointerleave", () => { hovering = false; render(); });
    tickListeners.push(() => {
      for (const app of roster) {
        for (const [key, spec] of Object.entries(switcherMetrics)) {
          if (key !== "memory") app[key] = walk(app[key], spec.step, 0.05, spec.max);
        }
      }
      if (!hovering) render();
    });
    render();
  }

  // MARK: Projects

  const servers = [
    { name: "docs-site", runtime: "Node", ports: [4321], memory: 212, activity: "Working", idle: false },
    { name: "storefront-web", runtime: "Node", ports: [4322, 6006], memory: 848, activity: "Idle 18m", idle: true },
    { name: "api", runtime: "Python", ports: [8000], memory: 96, activity: "Barely used", idle: true, warn: true },
    { name: "ledger", runtime: "Go", ports: [3000], memory: 38, activity: "Idle 3h 10m", idle: true },
  ];

  function projectsDemo(root) {
    const body = $(".pd-rows", root);
    const summary = $(".pd-summary", root);
    const toast = $(".pd-toast", root);
    const sheet = $(".pd-sheet", root);
    let running = servers.map((server) => ({ ...server }));
    let pending = [];
    let toastTimer;

    const ports = (list) => list.flatMap((s) => s.ports).join(", ");
    function render() {
      const idle = running.filter((s) => s.idle);
      summary.textContent = running.length === 0
        ? "No dev servers running."
        : `${running.length} dev servers · ${idle.length} idle${idle.length ? ` · stopping the idle ones frees ${idle.reduce((m, s) => m + s.memory, 0)} MB` : ""}`;
      $(".pd-stop-idle", root).disabled = idle.length === 0;
      body.replaceChildren(...running.map((server) => {
        const row = el("div", "pd-row");
        const name = el("span", "name", server.name);
        const act = el("span", server.warn ? "act warn" : "act", server.activity);
        const stop = el("button", "pd-stop", "Stop…");
        stop.type = "button";
        stop.addEventListener("click", () => ask([server]));
        row.append(name, el("span", "tag", server.runtime), el("span", "ports", server.ports.map((p) => `:${p}`).join(" ")),
          el("span", "mem", `${server.memory} MB`), act, stop);
        return row;
      }));
    }
    function ask(list) {
      pending = list;
      const total = list.reduce((m, s) => m + s.memory, 0);
      $(".pd-sheet-title", sheet).textContent = list.length === 1 ? `Stop “${list[0].name}”?` : `Stop ${list.length} idle dev servers?`;
      $(".pd-sheet-text", sheet).textContent = `${list.map((s) => s.name).join(", ")}. Frees ${total} MB and port${list.flatMap((s) => s.ports).length > 1 ? "s" : ""} ${ports(list)}.`;
      sheet.hidden = false;
      $(".pd-confirm", sheet).focus();
    }
    function confirmStop() {
      const names = pending.map((s) => s.name);
      const total = pending.reduce((m, s) => m + s.memory, 0);
      const freed = ports(pending);
      running = running.filter((s) => !names.includes(s.name));
      sheet.hidden = true;
      render();
      toast.textContent = `${names.length === 1 ? `${names[0]} stopped` : `${names.length} servers stopped`}. ${total} MB and ${freed.includes(",") ? "ports" : "port"} ${freed} are free.`;
      toast.hidden = false;
      clearTimeout(toastTimer);
      toastTimer = setTimeout(() => { toast.hidden = true; }, 4000);
    }
    $(".pd-stop-idle", root).addEventListener("click", () => ask(running.filter((s) => s.idle)));
    $(".pd-confirm", sheet).addEventListener("click", confirmStop);
    $(".pd-cancel", sheet).addEventListener("click", () => { sheet.hidden = true; });
    $(".pd-reset", root).addEventListener("click", () => { running = servers.map((s) => ({ ...s })); toast.hidden = true; render(); });
    render();
  }

  // MARK: Reveal on scroll

  function reveal() {
    const targets = $$(".reveal");
    if (reduceMotion || !("IntersectionObserver" in window)) {
      targets.forEach((t) => t.classList.add("in"));
      return;
    }
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          observer.unobserve(entry.target);
        }
      }
    }, { rootMargin: "0px 0px -10% 0px" });
    targets.forEach((t) => observer.observe(t));
  }

  function start() {
    const mbd = $("[data-mbd]");
    if (mbd) menuBarDemo(mbd);
    const ms = $("[data-switcher]");
    if (ms) switcherDemo(ms);
    const pd = $("[data-projects]");
    if (pd) projectsDemo(pd);
    reveal();
    // One tick a second while the tab is visible; nothing runs in a background tab.
    let timer;
    const run = () => { clearInterval(timer); if (!document.hidden) timer = setInterval(tick, reduceMotion ? 3000 : 1000); };
    document.addEventListener("visibilitychange", run);
    run();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
