// mactivity.app: a live replica of the Mactivity window, built from the app's own layout (sidebar,
// toolbar, per-metric colors, bar charts). Every figure is simulated; a web page can't read your Mac.
// No libraries, no storage, no network. Without JavaScript the section shows a screenshot instead.
(() => {
  "use strict";
  const root = document.querySelector("[data-replica]");
  if (!root) return;
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // MARK: Helpers

  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const icon = (name) => {
    const span = el("span", `ri ri-${name}`);
    span.setAttribute("aria-hidden", "true");
    span.innerHTML = ICONS[name] || "";
    return span;
  };
  const walk = (value, step, min, max) => Math.min(max, Math.max(min, value + (Math.random() - 0.5) * 2 * step));
  const gb = (bytes) => `${(bytes / 1e9).toFixed(bytes >= 1e10 ? 0 : 1)} GB`;
  const size = (mb) => (mb >= 1000 ? `${(mb / 1000).toFixed(1)} GB` : `${Math.round(mb)} MB`);
  const rate = (bps) => (bps >= 1e6 ? `${(bps / 1e6).toFixed(1)} MB/s` : `${Math.round(bps / 1e3)} kB/s`);
  // A seeded random, so the year of history looks the same on every visit.
  let seed = 7;
  const seeded = () => ((seed = (seed * 16807) % 2147483647) - 1) / 2147483646;

  // Our own line icons, drawn for this page (SF Symbols can't be used on the web).
  const s = (d) => `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
  const ICONS = {
    overview: s('<rect x="3" y="3" width="6" height="6" rx="1.5"/><rect x="11" y="3" width="6" height="6" rx="1.5"/><rect x="3" y="11" width="6" height="6" rx="1.5"/><rect x="11" y="11" width="6" height="6" rx="1.5"/>'),
    cpu: s('<rect x="5" y="5" width="10" height="10" rx="2"/><rect x="8" y="8" width="4" height="4" rx=".5"/><path d="M8 2v3M12 2v3M8 15v3M12 15v3M2 8h3M2 12h3M15 8h3M15 12h3"/>'),
    gpu: s('<path d="M10 2.5 16.5 6v8L10 17.5 3.5 14V6z"/><path d="M3.5 6 10 9.5 16.5 6M10 9.5v8"/>'),
    memory: s('<rect x="2.5" y="6" width="15" height="8" rx="1.5"/><path d="M6 9v2M9 9v2M12 9v2M15 9v2M5 14v2M8 14v2M12 14v2M15 14v2"/>'),
    disk: s('<path d="M4 11 6 5h8l2 6"/><rect x="3" y="11" width="14" height="5" rx="1.5"/><path d="M6 13.5h.01M9 13.5h5"/>'),
    network: s('<circle cx="10" cy="10" r="7.5"/><path d="M2.5 10h15M10 2.5c2.2 2.4 2.2 12.6 0 15M10 2.5c-2.2 2.4-2.2 12.6 0 15"/>'),
    battery: s('<rect x="2" y="6" width="14" height="8" rx="2"/><rect x="4" y="8" width="9" height="4" rx="1" fill="currentColor" stroke="none"/><path d="M18 9v2"/>'),
    projects: s('<path d="M12.5 3.5 16.5 7.5 8 16H4v-4z"/><path d="M11 5l4 4"/>'),
    agents: s('<path d="M8 3.5 9.3 7.7 13.5 9 9.3 10.3 8 14.5 6.7 10.3 2.5 9 6.7 7.7z"/><path d="M14.5 2.5l.6 1.9 1.9.6-1.9.6-.6 1.9-.6-1.9-1.9-.6 1.9-.6zM14.5 12.5l.5 1.5 1.5.5-1.5.5-.5 1.5-.5-1.5-1.5-.5 1.5-.5z"/>'),
    storage: s('<circle cx="10" cy="10" r="7.5"/><path d="M10 2.5V10l6.5 3.7"/>'),
    startup: s('<path d="M6.5 5.5a6.5 6.5 0 1 0 7 0"/><path d="M10 2.5V10"/>'),
    alerts: s('<path d="M5 13V9a5 5 0 0 1 10 0v4l1.5 2h-13z"/><path d="M8.5 17.5a1.7 1.7 0 0 0 3 0"/>'),
    history: s('<path d="M3.5 10a6.5 6.5 0 1 0 2-4.7"/><path d="M3 3.5v3h3M10 6.5V10l2.5 1.5"/>'),
    checkup: s('<path d="M10 2.5l2 1.6 2.5-.3.9 2.4 2.2 1.3-.6 2.5.6 2.5-2.2 1.3-.9 2.4-2.5-.3-2 1.6-2-1.6-2.5.3-.9-2.4-2.2-1.3.6-2.5-.6-2.5 2.2-1.3.9-2.4 2.5.3z"/><path d="m7.2 10.2 2 2 3.8-4"/>'),
    share: s('<path d="M10 12.5V3M7 5.5 10 2.5 13 5.5"/><path d="M6 8H5a1.5 1.5 0 0 0-1.5 1.5v6A1.5 1.5 0 0 0 5 17h10a1.5 1.5 0 0 0 1.5-1.5v-6A1.5 1.5 0 0 0 15 8h-1"/>'),
    search: s('<circle cx="9" cy="9" r="5.5"/><path d="m13 13 4 4"/>'),
    sidebar: s('<rect x="2.5" y="3.5" width="15" height="13" rx="2.5"/><path d="M7.5 3.5v13"/>'),
    chevron: s('<path d="m8 5 5 5-5 5"/>'),
    volume: s('<path d="M3 8v4h3l4 3.5v-11L6 8z"/><path d="M13 7.5a3.5 3.5 0 0 1 0 5M15.3 5.2a6.7 6.7 0 0 1 0 9.6"/>'),
    muted: s('<path d="M3 8v4h3l4 3.5v-11L6 8z"/><path d="m13.5 8 4 4M17.5 8l-4 4"/>'),
    reset: s('<path d="M4 10a6 6 0 1 0 1.8-4.3"/><path d="M4 3.5v3.2h3.2"/>'),
    devices: s('<rect x="1.5" y="4" width="8" height="6.5" rx="1.2"/><rect x="10.5" y="4" width="8" height="6.5" rx="1.2"/><path d="M4 14h3M5.5 10.5V14M13 14h3M14.5 10.5V14"/>'),
    laptop: s('<rect x="4" y="5" width="12" height="8" rx="1.2"/><path d="M2 15.5h16"/>'),
    display: s('<rect x="2.5" y="3.5" width="15" height="10" rx="1.5"/><path d="M7 17h6M10 13.5V17"/>'),
    plug: s('<path d="M2.5 10h4M13.5 10h4"/><rect x="6.5" y="7.5" width="7" height="5" rx="1"/>'),
    bolt: s('<path d="M11 2.5 4.5 11H10l-1 6.5L15.5 9H10z"/>'),
  };

  // MARK: The simulated Mac

  const APPS = [
    { id: "xcode", name: "Xcode", color: "#2f7bff", cpu: 6, gpu: 2, mem: 3.1, disk: 0.9, net: 0.02, energy: 102,
      procs: ["Xcode", "SourceKitService", "swift-frontend", "XCBBuildService"] },
    { id: "safari", name: "Safari", color: "#1aa7ff", cpu: 4, gpu: 3, mem: 2.0, disk: 0.04, net: 1.1, energy: 59,
      procs: ["Safari", "Safari Web Content", "Safari Web Content", "Safari Networking"] },
    { id: "macos", name: "macOS", color: "#8e8e93", cpu: 4, gpu: 1, mem: 2.5, disk: 0.15, net: 0.05, energy: 71,
      procs: ["kernel_task", "WindowServer", "mds_stores", "launchd"] },
    { id: "terminal", name: "Terminal", color: "#48484a", cpu: 3, gpu: 0, mem: 0.9, disk: 0.02, net: 0.06, energy: 43,
      procs: ["Terminal", "zsh", "node", "node", "python3"] },
    { id: "code", name: "Code", color: "#0f7fd1", cpu: 2, gpu: 1, mem: 1.0, disk: 0.03, net: 0.01, energy: 31,
      procs: ["Code", "Code Helper (Renderer)", "Code Helper (Plugin)", "Code Helper (GPU)"] },
    { id: "music", name: "Music", color: "#ff375f", cpu: 1, gpu: 1, mem: 0.5, disk: 0.06, net: 0.04, energy: 12,
      procs: ["Music", "AMPLibraryAgent", "AMPArtworkAgent"] },
    { id: "finder", name: "Finder", color: "#2fa3f7", cpu: 0.3, gpu: 0, mem: 0.2, disk: 0.01, net: 0, energy: 4,
      procs: ["Finder"] },
  ];
  const mac = {
    cpu: 21, user: 14, gpu: 8, memUsed: 19.4, memTotal: 36, wired: 3.7, compressed: 1.9, swap: 0.4,
    diskFree: 412, read: 2.1e5, write: 3.4e5, down: 5.6e5, up: 5.9e4, battery: 84, remaining: "5h 30m",
    temp: 54, fan: 2400, power: 11,
    recent: { cpu: [], gpu: [], memory: [], disk: [], network: [], battery: [] },
  };
  const METRICS = {
    cpu: { title: "CPU", color: "var(--cpu)", unit: "%" },
    gpu: { title: "GPU", color: "var(--gpu)", unit: "%" },
    memory: { title: "Memory", color: "var(--memory)", unit: "GB" },
    disk: { title: "Disk", color: "var(--disk)", unit: "GB" },
    network: { title: "Network", color: "var(--network)", unit: "" },
    battery: { title: "Battery", color: "var(--battery)", unit: "%" },
  };
  const ORDER = ["cpu", "gpu", "memory", "disk", "network", "battery"];
  const level = {
    cpu: () => mac.cpu / 100, gpu: () => mac.gpu / 100, memory: () => mac.memUsed / mac.memTotal,
    disk: () => Math.min(1, (mac.read + mac.write) / 1.2e6), network: () => Math.min(1, mac.down / 2e6), battery: () => mac.battery / 100,
  };
  function tick() {
    mac.cpu = walk(mac.cpu, 6, 5, 72);
    mac.user = Math.round(mac.cpu * 0.66);
    mac.gpu = walk(mac.gpu, 4, 1, 55);
    mac.memUsed = walk(mac.memUsed, 0.25, 16, 27);
    mac.read = walk(mac.read, 1.2e5, 1e4, 1.2e6);
    mac.write = walk(mac.write, 1.5e5, 1e4, 1.5e6);
    mac.down = walk(mac.down, 3e5, 1e4, 3e6);
    mac.up = walk(mac.up, 3e4, 2e3, 4e5);
    mac.temp = walk(mac.temp, 1.2, 44, 76);
    for (const app of APPS) {
      app.cpu = walk(app.cpu, 0.7, 0.1, 14);
      app.gpu = walk(app.gpu, 0.5, 0, 9);
      app.net = walk(app.net, 0.08, 0, 1.6);
    }
    for (const key of ORDER) {
      const list = mac.recent[key];
      list.push(level[key]());
      if (list.length > 60) list.shift();
    }
  }
  for (let i = 0; i < 60; i += 1) tick();

  // Thirty days at 15-minute steps, with a daily rhythm and a sleeping Mac at night.
  const HISTORY = {};
  for (const key of ORDER) {
    HISTORY[key] = [];
    for (let i = 0; i < 365 * 96; i += 1) {
      const hour = (i / 4) % 24;
      if (hour >= 1 && hour < 7) { HISTORY[key].push(null); continue; }
      const daily = 0.5 + 0.5 * Math.sin(((hour - 8) / 24) * 2 * Math.PI);
      const burst = seeded() < 0.06 ? 0.35 : 0;
      const base = { cpu: 0.18, gpu: 0.08, memory: 0.5, disk: 0.08, network: 0.1, battery: 0.6 }[key];
      const spread = { cpu: 0.45, gpu: 0.3, memory: 0.22, disk: 0.4, network: 0.5, battery: 0.35 }[key];
      HISTORY[key].push(Math.min(1, base + spread * daily * (0.6 + 0.4 * seeded()) + burst * (key === "memory" ? 0.2 : 1)));
    }
  }

  const headline = {
    cpu: () => [`${Math.round(mac.cpu)}%`, "15 cores"],
    gpu: () => [`${Math.round(mac.gpu)}%`, "Apple M5 Pro"],
    memory: () => [`${mac.memUsed.toFixed(0)} GB`, `used of ${mac.memTotal} GB`],
    disk: () => [`${mac.diskFree} GB`, "free on Macintosh HD"],
    network: () => [rate(mac.down), `down · ${rate(mac.up)} up`],
    battery: () => [`${mac.battery}%`, `${mac.remaining} remaining`],
  };
  const secondary = {
    cpu: () => [["User", `${mac.user}%`], ["System", `${Math.round(mac.cpu - mac.user)}%`], ["Idle", `${Math.round(100 - mac.cpu)}%`], ["Load average", `${(mac.cpu / 10).toFixed(2)}  ${(mac.cpu / 11).toFixed(2)}  1.76`]],
    gpu: () => {
      const top = APPS.reduce((a, b) => (b.gpu > a.gpu ? b : a));
      return [["Memory in use", "1.6 GB"], ["Most used by", `${top.name} ${Math.round(top.gpu)}%`], ["GPU temperature", `${Math.round(mac.temp - 6)}°`]];
    },
    memory: () => [["App", `${(mac.memUsed - mac.wired - mac.compressed).toFixed(1)} GB`], ["Wired", `${mac.wired} GB`], ["Compressed", `${mac.compressed} GB`], ["Swap used", `${mac.swap} GB`]],
    disk: () => [["Reading", rate(mac.read)], ["Writing", rate(mac.write)], ["Capacity", "995 GB"], ["Written today", "38.2 GB"]],
    network: () => [["Download", rate(mac.down)], ["Upload", rate(mac.up)], ["Today", "4.1 GB"], ["Interface", "Wi-Fi"]],
    battery: () => [["Source", "Battery"], ["Max capacity", "96%"], ["Cycle count", "212"], ["Power draw", `${mac.power} W`], ["CPU temperature", `${Math.round(mac.temp)}°`], ["AirPods Pro", "70%"]],
  };
  const appValue = {
    cpu: (a) => [a.cpu, `${a.cpu < 1 ? "<1" : Math.round(a.cpu)}%`],
    gpu: (a) => [a.gpu, `${a.gpu < 1 ? "<1" : Math.round(a.gpu)}%`],
    memory: (a) => [a.mem, gb(a.mem * 1e9)],
    disk: (a) => [a.disk, rate(a.disk * 1e6)],
    network: (a) => [a.net, rate(a.net * 1e6)],
    // Each app's share of all apps' Energy Impact, as the app shows it (D-112).
    battery: (a) => {
      const share = (a.energy / APPS.reduce((sum, x) => sum + x.energy, 0)) * 100;
      return [a.energy, share < 1 ? "<1%" : `${Math.round(share)}%`];
    },
  };

  // MARK: Window chrome

  // App icons as macOS draws them (scripts/demo-app-icons.swift); a letter for any other app.
  const APP_ICONS = { Xcode: "xcode", Safari: "safari", macOS: "macos", Terminal: "terminal", Code: "code", Music: "music",
    Finder: "finder", FaceTime: "facetime", Podcasts: "podcasts" };
  function appBadge(app, cls = "rw-badge") {
    const slug = APP_ICONS[app.name];
    if (!slug) {
      const letter = el("i", cls, app.name[0]);
      letter.style.background = app.color;
      return letter;
    }
    const img = el("img", `${cls} rw-app-icon`);
    img.src = `/icons/apps/${slug}.png`;
    img.alt = "";
    img.width = img.height = 32;
    return img;
  }

  // App chips: icon, name, and an optional figure; a click says what the app does with it.
  function appChips(apps, note) {
    const row = el("div", "rw-chips");
    for (const [name, color, figure, atLogin] of apps) {
      const chip = el("button", "rw-chip");
      chip.type = "button";
      chip.append(appBadge({ name, color }, "rw-badge small"), document.createTextNode(name));
      if (figure) chip.append(el("small", "", figure));
      if (atLogin) chip.append(el("small", "", "⏻"));
      chip.addEventListener("click", (event) => { event.stopPropagation(); toast(note(name)); });
      row.append(chip);
    }
    return row;
  }

  const SIDEBAR = [
    [null, ["overview", "checkup"]],
    ["Metrics", ORDER],
    ["More", ["projects", "agents", "storage", "startup", "volume", "devices", "alerts", "history"]],
  ];
  const TITLES = { overview: "Overview", checkup: "Checkup", projects: "Projects", agents: "Agents", storage: "Storage", startup: "Startup", volume: "Sound", devices: "Devices", alerts: "Alerts", history: "History" };
  for (const key of ORDER) TITLES[key] = METRICS[key].title;
  const TINTS = { overview: "var(--accent)", checkup: "#30d158", projects: "#b07a4f", agents: "#ff9f0a", storage: "#14b8a6", startup: "#2fb4d8", volume: "#ff375f", devices: "#5e5ce6", alerts: "#ff5a52", history: "#8e5cf7" };
  for (const key of ORDER) TINTS[key] = METRICS[key].color;

  // Per-app volume (the app's Sound tab): what each app playing audio is set to.
  const OUTPUTS = ["System default", "MacBook Pro Speakers", "AirPods Pro", "Studio Display Speakers"];
  const AUDIO = [
    { name: "Music", color: "#ff375f", volume: 70, muted: false, output: "AirPods Pro" },
    { name: "Safari", color: "#1aa7ff", volume: 100, muted: false, output: "System default" },
    { name: "FaceTime", color: "#30d158", volume: 45, muted: false, output: "Studio Display Speakers" },
    { name: "Podcasts", color: "#a855f7", volume: 100, muted: true, output: "System default" },
  ];
  const untouched = (a) => a.volume === 100 && !a.muted && a.output === "System default";

  // Storage → Clean Up (D-116 to D-118): what each sheet lists. [name, detail, MB, ticked]
  const CLEANUP = {
    messages: {
      title: "Messages Attachments",
      intro: "This Mac's copies of photos, videos and files from Messages, older than a year. The messages stay, and so does everything on your iPhone.",
      rows: [["IMG_4411.MOV", "Video · Apr 12, 2025", 412, true], ["Screen Recording.mov", "Video · Oct 29, 2024", 288, true],
        ["Tahoe trip.mp4", "Video · Aug 5, 2025", 190, true], ["Lease.pdf", "Document · Jul 21, 2024", 4, true], ["IMG_2210.HEIC", "Photo · May 17, 2025", 3, true]],
    },
    backups: {
      title: "iPhone and iPad Backups",
      intro: "Finder's backups of your devices. A backup may be the only copy of a device you no longer have, so none is ticked until you tick it.",
      rows: [["iPhone", "iPhone 17 Pro · iOS 26.0 · Sep 27, 2026 · Encrypted", 61000, false], ["Old iPad", "iPad Air · iPadOS 17.5 · Oct 29, 2024", 23000, false],
        ["iPhone18,1_26.0_Restore.ipsw", "Downloaded update · Finder gets it again when needed", 9800, true]],
    },
    downloads: {
      title: "Installers and Archives in Downloads",
      intro: "Disk images, installers and archives kept after installing, and downloads that never finished. Ticked: added over 30 days ago.",
      rows: [["Xcode_27.xip", "Archive · added Jul 31, 2026", 11400, true], ["Docker.dmg", "Disk image · added Jun 1, 2026", 640, true],
        ["Zoom.pkg", "Installer · added Sep 26, 2026", 190, false], ["movie.mp4.crdownload", "Unfinished download · added Sep 20, 2026", 80, true]],
    },
    screenshots: {
      title: "Screenshots and Screen Recordings",
      intro: "Captures macOS saved to your screenshot folder and the Desktop, found by macOS's own mark, in any language. Ticked: over 30 days old.",
      rows: [["Screen Recording 2026-06-12.mov", "Screen recording · Jun 12, 2026", 2400, true], ["Screen Recording 2026-08-03.mov", "Screen recording · Aug 3, 2026", 910, true],
        ["Screenshot 2026-09-28 at 5.11 PM.png", "Screenshot · Sep 28, 2026", 1, false]],
    },
    developer: {
      title: "Developer Caches",
      intro: "Build products and downloads that come back by themselves: Xcode rebuilds, package managers download again. Quit Xcode before moving DerivedData.",
      rows: [["npm cache", "Package tarballs. npm downloads them again.", 3200, true], ["Xcode DerivedData", "Build products and indexes. Xcode rebuilds them.", 2900, true],
        ["pip cache", "Wheels and downloads. pip fetches them again.", 156, true], ["Homebrew cache", "Downloaded bottles. Homebrew gets them again.", 106, true]],
    },
    // Purgeable Space (D-125): removes iCloud downloads (the files stay in iCloud); snapshots are listed only.
    purgeable: {
      title: "Purgeable Space",
      intro: "macOS frees this on its own when it needs room: caches apps marked as purgeable, iCloud copies, and old snapshots. iCloud files kept on this Mac can go sooner.",
      action: "Remove Downloads…",
      done: (size) => `Removed ${size} of downloads. The files are still in iCloud.`,
      note: "Local Time Machine snapshots: 2, from today. macOS keeps each about a day, and deletes them sooner when it needs the space.",
      rows: [["IMG_0952.MOV", "iCloud Drive", 175, false], ["Tahoe trip.mov", "iCloud Drive", 172, false],
        ["Portfolio.key", "Keynote", 96, false], ["Taxes 2025.pdf", "iCloud Drive", 12, false]],
    },
    mail: {
      title: "Mail Downloads",
      intro: "Copies of attachments Mail saved when you opened them. The messages keep their attachments. Ticked: saved over 30 days ago.",
      rows: [["Photos.zip", "Saved Jun 3, 2026", 420, true], ["Contract.pdf", "Saved Aug 14, 2026", 38, true], ["Invoice.pdf", "Saved Sep 28, 2026", 1, false]],
    },
  };
  const mb = (v) => (v >= 1000 ? `${(v / 1000).toFixed(v >= 10000 ? 0 : 1)} GB` : `${v} MB`);

  const state = { selection: "overview", alertsTab: "recent", batterySpan: "now", cleanupMenu: false, sheet: null, range: "24 h", expanded: new Set(), stopped: new Set(), confirm: null, toast: "" };

  root.replaceChildren();
  const win = el("div", "rw-window");
  const side = el("div", "rw-sidebar");
  side.setAttribute("role", "navigation");
  side.setAttribute("aria-label", "Mactivity sidebar");
  const lights = el("div", "rw-lights");
  lights.append(el("i"), el("i"), el("i"), icon("sidebar"));
  side.append(lights);
  for (const [heading, items] of SIDEBAR) {
    if (heading) side.append(el("p", "rw-section", heading));
    for (const key of items) {
      const button = el("button", "rw-item");
      button.type = "button";
      button.dataset.key = key;
      const glyph = icon(key === "overview" ? "overview" : key);
      glyph.style.color = TINTS[key];
      button.append(glyph, el("span", "", TITLES[key]));
      button.addEventListener("click", () => select(key));
      side.append(button);
    }
  }
  const main = el("div", "rw-main");
  const bar = el("header", "rw-toolbar");
  const content = el("div", "rw-content");
  content.tabIndex = 0;
  content.setAttribute("aria-live", "off");
  main.append(bar, content);
  win.append(side, main);
  const note = el("p", "rw-note", "Every button works. The figures are sample data: a web page can't read your Mac, and shouldn't.");
  root.append(win, note);

  function select(key) {
    state.selection = key;
    state.alertsTab = "recent";
    state.confirm = null;
    state.sheet = null;
    state.cleanupMenu = false;
    content.scrollTop = 0;
    render();
  }

  function renderToolbar() {
    bar.replaceChildren();
    const titles = el("div", "rw-titles");
    const apps = APPS.length + 1;
    titles.append(el("b", "", TITLES[state.selection]), el("small", "", `${apps} apps · 28 processes · Up 9d 4h`));
    bar.append(titles, el("span", "rw-spacer"));
    if (ORDER.includes(state.selection) || state.selection === "history") {
      const seg = el("div", "rw-seg");
      for (const range of ["12 h", "24 h", "7 d", "30 d", "90 d", "1 y"]) {
        const b = el("button", range === state.range ? "on" : "", range);
        b.type = "button";
        b.addEventListener("click", () => { state.range = range; render(); });
        seg.append(b);
      }
      bar.append(seg);
    }
    // Alerts opens on what went off; the rules are the other half (D-238).
    if (state.selection === "alerts") {
      const seg = el("div", "rw-seg");
      for (const [tab, label] of [["recent", "Recent"], ["rules", "Rules"]]) {
        const b = el("button", tab === state.alertsTab ? "on" : "", label);
        b.type = "button";
        b.addEventListener("click", () => { state.alertsTab = tab; render(); });
        seg.append(b);
      }
      bar.append(seg);
    }
    // Why is my Mac slow? (D-134): a sample diagnosis.
    const slow = el("button", "rw-button", "Diagnose");
    slow.type = "button";
    slow.title = "Why is my Mac slow?";
    slow.addEventListener("click", () => { state.sheet = "slow"; state.cleanupMenu = false; render(); });
    bar.append(slow);
    const search = el("button", "rw-button with-icon");
    search.type = "button";
    search.title = "Quick Search (⌃⌥M)";
    search.append(icon("search"), document.createTextNode("Search"));
    search.addEventListener("click", () => { state.sheet = "search"; state.cleanupMenu = false; render(); });
    bar.append(search);
    const share = el("button", "rw-glass");
    share.type = "button";
    share.setAttribute("aria-label", "Share");
    share.append(icon("share"));
    share.addEventListener("click", () => toast("Share makes a card of your Mac's figures, to post or send."));
    bar.append(share);
    if (ORDER.includes(state.selection)) {
      const search = el("div", "rw-search");
      search.append(icon("search"), el("span", "", "Search apps"));
      bar.append(search);
    }
  }

  // MARK: Building blocks

  function bars(values, color, cls = "rw-bars") {
    const wrap = el("div", cls);
    for (const v of values) {
      const b = el("i");
      if (v === null) b.className = "gap";
      else b.style.height = `${Math.max(3, Math.round(v * 100))}%`;
      b.style.background = color;
      wrap.append(b);
    }
    return wrap;
  }
  function card(cls = "") {
    return el("div", `rw-card ${cls}`);
  }
  function headlineCard(key, big = false) {
    const c = card(big ? "rw-headline big" : "rw-headline");
    c.addEventListener("click", () => { if (!big) select(key); });
    const head = el("div", "rw-card-head");
    const title = el("span", "rw-card-title");
    const glyph = icon(key);
    glyph.style.color = METRICS[key].color;
    title.append(glyph, document.createTextNode(METRICS[key].title));
    const status = el("span", "rw-status", key === "network" ? "" : "Normal");
    head.append(title, status);
    const [figure, caption] = headline[key]();
    c.append(head, el("div", "rw-figure", figure), el("div", "rw-caption", caption), bars(mac.recent[key].slice(big ? -60 : -40), METRICS[key].color));
    return c;
  }
  function donut(title, glyph, parts, center, sub) {
    const c = card("rw-donut");
    const head = el("div", "rw-card-title");
    head.append(icon(glyph), document.createTextNode(title));
    const body = el("div", "rw-donut-body");
    const total = parts.reduce((sum, [, v]) => sum + v, 0);
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 42 42");
    let offset = 25;
    for (const [, v, color] of parts) {
      const ring = document.createElementNS(ns, "circle");
      ring.setAttribute("cx", "21"); ring.setAttribute("cy", "21"); ring.setAttribute("r", "15.9");
      ring.setAttribute("fill", "none"); ring.setAttribute("stroke-width", "5");
      ring.setAttribute("stroke", color);
      const share = (v / total) * 100;
      ring.setAttribute("stroke-dasharray", `${Math.max(0, share - 1.2)} ${100 - share + 1.2}`);
      ring.setAttribute("stroke-dashoffset", String(offset));
      offset -= share;
      svg.append(ring);
    }
    const middle = el("div", "rw-donut-center");
    middle.append(el("b", "", center), el("small", "", sub));
    const ring = el("div", "rw-ring");
    ring.append(svg, middle);
    const legend = el("div", "rw-legend");
    for (const [label, v, color, text] of parts) {
      const row = el("div");
      const dot = el("i");
      dot.style.background = color;
      row.append(dot, el("span", "", label), el("b", "", text || v));
      legend.append(row);
    }
    body.append(ring, legend);
    c.append(head, body);
    return c;
  }
  function appRows(key) {
    const list = el("div", "rw-apps");
    const ranked = [...APPS].sort((a, b) => appValue[key](b)[0] - appValue[key](a)[0]);
    for (const app of ranked) {
      const open = state.expanded.has(app.id);
      const row = el("button", `rw-app${open ? " open" : ""}`);
      row.type = "button";
      row.setAttribute("aria-expanded", String(open));
      const chev = icon("chevron");
      const badge = appBadge(app);
      row.append(chev, badge, el("span", "rw-app-name", app.name), el("small", "", `${app.procs.length} processes`),
        el("span", "rw-spacer"), el("b", "", appValue[key](app)[1]));
      row.addEventListener("click", () => {
        if (state.expanded.has(app.id)) state.expanded.delete(app.id); else state.expanded.add(app.id);
        render();
      });
      list.append(row);
      if (open) {
        const [value] = appValue[key](app);
        app.procs.forEach((name, i) => {
          const child = el("div", "rw-proc");
          const share = [0.46, 0.27, 0.16, 0.08, 0.03][i] || 0.02;
          const [, text] = appValue[key]({ ...app, cpu: value * share, gpu: value * share, mem: value * share, disk: value * share, net: value * share, energy: value * share });
          child.append(el("span", "", name), el("span", "rw-spacer"), el("b", "", text));
          list.append(child);
        });
      }
    }
    return list;
  }
  function historyStrip(key, withApps = true) {
    const c = card("rw-history");
    const count = { "12 h": 48, "24 h": 96, "7 d": 7 * 96, "30 d": 30 * 96, "90 d": 90 * 96, "1 y": 365 * 96 }[state.range];
    const series = HISTORY[key].slice(-count);
    // Bucket into at most 96 bars; a bucket with no samples is a gap (the Mac was asleep).
    const step = Math.max(1, Math.ceil(series.length / 96));
    const bucketed = [];
    for (let i = 0; i < series.length; i += step) {
      const slice = series.slice(i, i + step).filter((v) => v !== null);
      bucketed.push(slice.length ? slice.reduce((m, v) => m + v, 0) / slice.length : null);
    }
    const values = bucketed.filter((v) => v !== null);
    const avg = values.reduce((m, v) => m + v, 0) / values.length;
    const peak = Math.max(...values);
    const fmt = (v) => (key === "memory" ? `${Math.round(v * mac.memTotal)} GB` : key === "network" ? rate(v * 2e6) : key === "disk" ? rate(v * 1.2e6) : `${Math.round(v * 100)}%`);
    const chart = el("div", "rw-history-chart");
    const head = el("div", "rw-history-head");
    head.append(el("b", "", "History"), el("span", "", `${fmt(avg)} average · peak ${fmt(peak)}`));
    chart.append(head, bars(bucketed, METRICS[key].color, "rw-bars tall"));
    c.append(chart);
    if (withApps) {
      const top = el("div", "rw-top");
      const head2 = el("div", "rw-top-head");
      head2.append(el("b", "", `Top apps · ${state.range}`), el("span", "rw-chip", "vs previous"));
      top.append(head2);
      const ranked = [...APPS].sort((a, b) => appValue[key](b)[0] - appValue[key](a)[0]).slice(0, 5);
      const changes = ["+12%", "Same", "−8%", "+25%", "New"];
      ranked.forEach((app, i) => {
        const row = el("div", "rw-top-row");
        const badge = appBadge(app, "rw-badge small");
        row.append(badge, el("span", "", app.name), el("span", "rw-spacer"), el("small", "", changes[i]), el("b", "", appValue[key](app)[1]));
        top.append(row);
      });
      c.append(top);
    }
    return c;
  }
  /// Battery use by app: each app's share of the battery while unplugged (sample figures).
  function batteryUse(span) {
    const c = card("rw-rules");
    const summary = span === "today" ? "On battery 3h 20m · used 42%" : "On battery 21h 5m · used 318%";
    const head = el("div", "rw-history-head");
    head.append(el("span", "", summary), el("span", "", "Health 96% · Cycles: 212 · About 14 months to 80% at this rate"));
    c.append(head);
    const shares = span === "today" ? [0.41, 0.22, 0.14, 0.09, 0.06] : [0.37, 0.25, 0.12, 0.1, 0.07];
    APPS.slice(0, 5).forEach((app, i) => {
      const row = el("div", "rw-top-row");
      const b = appBadge(app);
      const meter = el("div", "rw-meter");
      meter.style.flex = "1";
      const fill = el("i");
      fill.style.width = `${shares[i] * 100 / shares[0]}%`;
      fill.style.background = "var(--battery)";
      meter.append(fill);
      const name = el("span", "", app.name);
      name.style.width = "140px";
      row.append(b, name, meter, el("b", "", `${Math.round(shares[i] * 100)}%`));
      c.append(row);
    });
    return c;
  }

  function sectionTitle(text, glyph, color) {
    const h = el("h4", "rw-h");
    if (glyph) {
      const g = icon(glyph);
      if (color) g.style.color = color;
      h.append(g);
    }
    h.append(document.createTextNode(text));
    return h;
  }

  // A symbol, white on a rounded square of its color, as the app marks alerts and Checkup (D-239).
  function badge(glyph, color) {
    const b = el("span", "rw-symbol-badge");
    b.style.background = color;
    b.append(icon(glyph));
    return b;
  }

  // MARK: Pages

  const PAGES = {
    overview() {
      const grid = el("div", "rw-grid three");
      for (const key of ORDER) grid.append(headlineCard(key));
      const donuts = el("div", "rw-grid three");
      const app = mac.memUsed - mac.wired - mac.compressed;
      donuts.append(
        donut("Memory by type", "memory", [
          ["App", app, "var(--cpu)", `${app.toFixed(0)} GB`], ["Wired", mac.wired, "var(--memory)", `${mac.wired} GB`],
          ["Compressed", mac.compressed, "var(--gpu)", `${mac.compressed} GB`], ["Cached files", 8.6, "var(--network)", "8.6 GB"],
          ["Free", mac.memTotal - mac.memUsed - 8.6, "#8e8e93", `${(mac.memTotal - mac.memUsed - 8.6).toFixed(1)} GB`],
        ], `${Math.round((mac.memUsed / mac.memTotal) * 100)}%`, "in use"),
        donut("Memory by app", "overview", APPS.slice(0, 4).map((a, i) => [a.name, a.mem, ["var(--cpu)", "var(--memory)", "var(--gpu)", "var(--network)"][i], gb(a.mem * 1e9)])
          .concat([["Other", 2.2, "#8e8e93", "2.2 GB"]]), "11 GB", "all apps"),
        donut("Power by app", "battery", APPS.slice(0, 4).map((a, i) => [a.name, a.energy * 2.7, ["var(--cpu)", "var(--memory)", "var(--gpu)", "var(--network)"][i], `${Math.round(a.energy * 2.7)} mW`])
          .concat([["Other", 190, "#8e8e93", "190 mW"]]), "1.0 W", "all apps"),
      );
      return [grid, unusualCard(), donuts];
    },
    metric(key) {
      const top = el("div", "rw-grid two");
      top.append(headlineCard(key, true));
      const figures = card("rw-figures");
      for (const [label, value] of secondary[key]()) {
        const f = el("div");
        f.append(el("small", "", label), el("b", "", value));
        figures.append(f);
      }
      top.append(figures);
      if (key === "battery") {
        // Now is the live list; Today and 7 days show what used the battery, as in the app.
        const head = el("div", "rw-projects-head");
        const seg = el("div", "rw-seg");
        for (const [span, label] of [["now", "Now"], ["today", "Today"], ["week", "7 days"]]) {
          const b = el("button", state.batterySpan === span ? "on" : "", label);
          b.type = "button";
          b.addEventListener("click", () => { state.batterySpan = span; render(); });
          seg.append(b);
        }
        head.append(sectionTitle(state.batterySpan === "now" ? "Energy Impact by app" : "Battery use by app"), el("span", "rw-spacer"), seg);
        return [top, historyStrip(key), head, state.batterySpan === "now" ? appRows(key) : batteryUse(state.batterySpan)];
      }
      if (key === "network") {
        // Hotspot data watch (D-136): on an iPhone's hotspot, what each app has used.
        const hot = card("rw-rules");
        const head = el("div", "rw-rule");
        head.append(el("b", "", "On a metered connection, like your iPhone's hotspot"), el("span", "rw-spacer"), el("em", "", "412 MB"));
        hot.append(head, el("small", "rw-caption", "Used since 2:41 PM. Mactivity alerts you when an app uses a lot."));
        for (const [name, used] of [["iCloud Drive", "268 MB"], ["Safari", "96 MB"], ["Dropbox", "31 MB"]]) {
          const row = el("div", "rw-rule");
          row.append(el("span", "", name), el("span", "rw-spacer"), el("em", "", used));
          hot.append(row);
        }
        return [top, historyStrip(key), hot, sectionTitle("Apps"), appRows(key)];
      }
      return [top, historyStrip(key), sectionTitle("Apps"), appRows(key)];
    },
    checkup() {
      // Worth doing soon, then worth knowing, each in the color of the page it opens (D-239).
      const items = [
        ["attention", "disk", "Your startup disk fills up in about 2 weeks", "At the rate of the last 30 days. Storage shows what's taking the space.", "storage"],
        ["attention", "alerts", "Xcode crashes this week: 4", "An update often fixes it. History → Crashes and hangs has the reports.", "history"],
        ["suggestion", "battery", "Battery health reaches 80% in about 9 months", "At its rate over the last year. Optimized Battery Charging, in System Settings → Battery, slows this.", "battery"],
        ["suggestion", "history", "Keeping your Mac awake: Music", "While it runs, your Mac won't sleep when idle. Quit it when you're done to save power.", "history"],
        ["suggestion", "startup", "Broken startup items: 2", "They point to apps or files that are gone. Startup shows them.", "startup"],
        ["suggestion", "projects", "Idle dev servers: 2", "They hold 1.1 GB. Projects can stop them.", "projects"],
        ["suggestion", "memory", "Open but unused for days: Docker Desktop and Keynote", "Together they hold 2.9 GB of memory. Quitting frees it.", "unused"],
      ];
      const colors = { disk: METRICS.disk.color, alerts: "#ff453a", battery: METRICS.battery.color, history: "#5e5ce6",
        startup: TINTS.startup, projects: TINTS.projects, memory: METRICS.memory.color };
      const nodes = [];
      for (const [severity, heading] of [["attention", "Worth doing soon"], ["suggestion", "Worth knowing"]]) {
        nodes.push(sectionTitle(heading));
        const list = card("rw-rules");
        for (const [level, glyph, title, detail, target] of items) {
          if (level !== severity) continue;
          const row = el("button", "rw-rule rw-row-button");
          row.type = "button";
          const text = el("div");
          text.append(el("b", "", title), el("small", "", detail));
          row.append(badge(glyph, colors[glyph]), text, el("span", "rw-spacer"), icon("chevron"));
          row.addEventListener("click", () => {
            if (target === "unused") { state.sheet = "unused"; render(); return; }
            select(target);
          });
          list.append(row);
        }
        nodes.push(list);
      }
      return nodes;
    },
    projects() {
      const servers = [
        ["docs-site", "Node", ":4321", 212, "2h", "Working"], ["storefront-web", "Node", ":4322  :6006", 848, "5h", "Idle 18m"],
        ["api", "Python", ":8000", 96, "1d 6h", "Barely used"], ["ledger", "Go", ":3000", 38, "2d 2h", "Idle 3h 10m"],
      ].filter(([name]) => !state.stopped.has(name));
      const idle = servers.filter((s) => s[5] !== "Working");
      const head = card("rw-projects-head");
      const count = `${servers.length} dev server${servers.length === 1 ? "" : "s"}`;
      const freed = idle.reduce((m, s) => m + s[3], 0);
      head.append(el("b", "", servers.length === 0 ? "No dev servers running"
        : idle.length === 0 ? `${count} · none idle`
        : `${count} · ${idle.length} idle · stop the idle ones to get back ${freed} MB`));
      const stopIdle = el("button", "rw-button prominent", "Stop Idle…");
      stopIdle.type = "button";
      stopIdle.disabled = idle.length === 0;
      stopIdle.addEventListener("click", () => { state.confirm = idle.map((s) => s[0]); render(); });
      head.append(el("span", "rw-spacer"), stopIdle);
      const table = card("rw-table");
      const header = el("div", "rw-tr th");
      ["Project", "Runtime", "Ports", "Memory", "Up", "Activity", ""].forEach((h) => header.append(el("span", "", h)));
      table.append(header);
      for (const [name, runtime, ports, memory, up, activity] of servers) {
        const tr = el("div", "rw-tr");
        const stop = el("button", "rw-button", "Stop…");
        stop.type = "button";
        stop.addEventListener("click", () => { state.confirm = [name]; render(); });
        tr.append(el("b", "", name), el("span", "rw-tag", runtime), el("code", "", ports), el("span", "", `${memory} MB`), el("span", "", up),
          el("span", activity === "Barely used" ? "amber" : "muted", activity), stop);
        table.append(tr);
      }
      const docker = card("rw-table");
      const dh = el("div", "rw-tr th");
      ["Container", "Image", "State", "CPU", "Memory"].forEach((h) => dh.append(el("span", "", h)));
      docker.append(dh);
      for (const [name, image, cpu, memory] of [["api-postgres-1", "postgis/postgis:16-3.4", "<1%", "96 MB"], ["storefront-web-db-1", "postgres:16-alpine", "2%", "212 MB"], ["storefront-web-redis-1", "redis:7", "<1%", "14 MB"]]) {
        const tr = el("div", "rw-tr five");
        const running = el("span", "running", "Running");
        tr.append(el("b", "", name), el("code", "", image), running, el("span", "", cpu), el("span", "", memory));
        docker.append(tr);
      }
      return [head, table, sectionTitle("Docker Desktop · 3 running", "gpu", "#1d8cf8"), docker];
    },
    // The Agents tab (D-148): AI coding agent sessions, with everything each one started.
    agents() {
      const sessions = [
        ["Claude Code", "node, vitest", "Terminal", "storefront-web", "7.8%", "1.2 GB", 9, "42m"],
        ["Codex", "python3.13", "iTerm", "api", "1.2%", "410 MB", 4, "3h 0m"],
        ["Claude Code", "", "Claude", "docs-site", "0.3%", "286 MB", 2, "15m"],
      ].filter(([agent, , , project]) => !state.stopped.has(`${agent} in ${project}`));
      const head = card("rw-projects-head");
      head.append(el("b", "", sessions.length === 0 ? "No AI agents running" : `Agent sessions: ${sessions.length}`));
      const table = card("rw-table");
      const header = el("div", "rw-tr th");
      ["Agent", "In", "Project", "CPU", "Memory", "Running", ""].forEach((h) => header.append(el("span", "", h)));
      table.append(header);
      for (const [agent, children, host, project, cpu, memory, count, running] of sessions) {
        const tr = el("div", "rw-tr");
        const name = el("span");
        name.append(el("b", "", agent));
        if (children) name.append(el("small", "muted", ` ${children}`));
        const stop = el("button", "rw-button", "Stop…");
        stop.type = "button";
        stop.addEventListener("click", () => { state.confirm = { agent, project, count }; render(); });
        tr.append(name, el("span", "muted", host), el("span", "", project), el("span", "", cpu), el("span", "", memory),
          el("span", "", running), stop);
        table.append(tr);
      }
      // Agent history (D-192): the week, from what Mactivity recorded each minute.
      const week = card("rw-agent-week");
      const top = el("div", "rw-agent-week-head");
      top.append(el("b", "", "This week"), el("small", "muted", "35h 45m of agent time across 3 projects"));
      const bars = el("div", "rw-weekbars");
      [["T", 8], ["F", 6], ["S", 1], ["S", 0], ["M", 6], ["T", 8], ["W", 6]].forEach(([day, hours], index) => {
        const column = el("div", index === 0 ? "rw-weekbar most" : "rw-weekbar");
        const bar = el("i");
        bar.style.height = `${(hours / 8) * 100}%`;
        if (!hours) bar.style.minHeight = "0";
        column.append(el("small", "", hours ? `${hours}h` : ""), bar, el("span", "", day));
        bars.append(column);
      });
      const rows = card("rw-table rw-agent-week-table");
      const th = el("div", "rw-tr five th");
      ["Agent", "Project", "Time", "Processor", "Peak memory"].forEach((h) => th.append(el("span", "", h)));
      rows.append(th);
      for (const [agent, project, time, cpu, memory] of [
        ["Claude Code", "mactivity", "32h 30m", "7.1%", "1.8 GB"], ["Codex", "api", "4h", "2.9%", "572 MB"], ["Claude Code", "docs-site", "1h 15m", "4.0%", "858 MB"],
      ]) {
        const tr = el("div", "rw-tr five");
        tr.append(el("b", "", agent), el("span", "muted", project), el("span", "", time), el("span", "", cpu), el("span", "", memory));
        rows.append(tr);
      }
      const body = el("div", "rw-agent-week-body");
      body.append(bars, rows);
      week.append(top, body);
      return [head, table, week];
    },
    storage() {
      const wrap = el("div", "rw-grid storage");
      const folders = [["Library", 126, "var(--cpu)"], ["Movies", 81, "var(--memory)"], ["Pictures", 64, "var(--network)"], ["Downloads", 33, "var(--disk)"],
        ["Music", 28, "#5e5ce6"], ["Developer", 25, "#14b8a6"], ["Documents", 21, "#64d2ff"], ["Other", 12, "#8e8e93"]];
      const total = folders.reduce((m, [, v]) => m + v, 0);
      const ns = "http://www.w3.org/2000/svg";
      const svg = document.createElementNS(ns, "svg");
      svg.setAttribute("viewBox", "-50 -50 100 100");
      const arc = (r1, r2, a1, a2, color, opacity) => {
        const p = (r, a) => `${(r * Math.sin(a)).toFixed(2)} ${(-r * Math.cos(a)).toFixed(2)}`;
        const large = a2 - a1 > Math.PI ? 1 : 0;
        const path = document.createElementNS(ns, "path");
        path.setAttribute("d", `M${p(r1, a1)} A${r1} ${r1} 0 ${large} 1 ${p(r1, a2)} L${p(r2, a2)} A${r2} ${r2} 0 ${large} 0 ${p(r2, a1)}Z`);
        path.setAttribute("fill", color);
        path.setAttribute("fill-opacity", String(opacity));
        path.setAttribute("stroke", "var(--rw-card)");
        path.setAttribute("stroke-width", ".6");
        svg.append(path);
      };
      let angle = 0;
      for (const [, v, color] of folders) {
        const span = (v / total) * 2 * Math.PI;
        arc(18, 30, angle, angle + span, color, 1);
        // An outer ring of subfolders, so it reads as a map.
        let inner = angle;
        for (const part of [0.45, 0.25, 0.18, 0.12]) {
          arc(31, 31 + 6 + part * 20, inner, inner + span * part, color, 0.55);
          inner += span * part;
        }
        angle += span;
      }
      const ring = el("div", "rw-sunburst");
      const middle = el("div", "rw-donut-center");
      middle.append(el("b", "", `${total} GB`), el("small", "", "home folder"));
      ring.append(svg, middle);
      const mapCard = card("rw-map");
      mapCard.append(ring, el("p", "rw-caption center", "Home folder · 1,325,865 files · scanned in 4.2 s"));
      const list = card("rw-folders");
      for (const [name, v, color] of folders) {
        const row = el("div", "rw-folder");
        const dot = el("i");
        dot.style.background = color;
        const meter = el("span", "rw-meter");
        const fill = el("i");
        fill.style.width = `${(v / folders[0][1]) * 100}%`;
        fill.style.background = color;
        meter.append(fill);
        row.append(dot, el("span", "", name), meter, el("b", "", `${v} GB`));
        list.append(row);
      }
      wrap.append(mapCard, list);
      const volume = card("rw-volume");
      const meter = el("div", "rw-capacity");
      for (const [w, color] of [[65, "var(--cpu)"], [3, "#9ec1ff"], [32, "rgba(127,127,127,.2)"]]) {
        const part = el("i");
        part.style.width = `${w}%`;
        part.style.background = color;
        meter.append(part);
      }
      const head = el("div", "rw-volume-head");
      const names = el("span");
      names.append(el("b", "", "Macintosh HD"), el("small", "", "  APFS · 995 GB · 348 GB available"));
      const menuWrap = el("span", "rw-menu-wrap");
      const clean = el("button", "rw-button", "Clean Up ▾");
      clean.type = "button";
      clean.setAttribute("aria-haspopup", "menu");
      clean.setAttribute("aria-expanded", String(state.cleanupMenu));
      clean.addEventListener("click", () => { state.cleanupMenu = !state.cleanupMenu; render(); });
      menuWrap.append(clean);
      if (state.cleanupMenu) {
        const menu = el("div", "rw-menu");
        menu.setAttribute("role", "menu");
        for (const [key, label] of [["uninstall", "Uninstall App…"], ["messages", "Messages Attachments…"], ["backups", "iPhone and iPad Backups…"],
          ["downloads", "Installers and Archives in Downloads…"], ["screenshots", "Screenshots and Screen Recordings…"], ["mail", "Mail Downloads…"], ["developer", "Developer Caches…"], ["purgeable", "Purgeable Space…"]]) {
          const item = el("button", "", label);
          item.type = "button";
          item.setAttribute("role", "menuitem");
          item.addEventListener("click", () => {
            state.cleanupMenu = false;
            if (key === "uninstall") {
              toast("Uninstall App… opens a picker: choose an app, see what it left in your Library, then move it all to the Trash.");
              return;
            }
            state.sheet = key;
            render();
          });
          menu.append(item);
        }
        menuWrap.append(menu);
      }
      head.append(names, menuWrap);
      volume.append(head, meter);
      // Space you can get back (D-119): each cleanup's ticked rows, with Review… opening its sheet.
      const lines = [["backups", "iPhone and iPad backups older than six months"], ["downloads", "Installers and archives in Downloads"],
        ["developer", "Developer caches that rebuild themselves"], ["screenshots", "Screenshots and recordings over 30 days old"], ["messages", "Messages attachments older than a year"], ["mail", "Mail downloads older than 30 days"]]
        .map(([key, title]) => [key, title, key === "backups" ? CLEANUP.backups.rows.filter((r) => !r[1].startsWith("Downloaded")).slice(1).reduce((m, r) => m + r[2], 0)
          : CLEANUP[key].rows.filter((r) => r[3]).reduce((m, r) => m + r[2], 0)])
        .filter(([, , size]) => size >= 50)
        .sort((a, b) => b[2] - a[2]);
      const reclaim = card("rw-rules rw-reclaim");
      if (lines.length) {
        const head2 = el("div", "rw-rule");
        head2.append(el("b", "", `Space you can get back: ${mb(lines.reduce((m, l) => m + l[2], 0))}`));
        reclaim.append(head2);
        for (const [key, title, size] of lines) {
          const row = el("div", "rw-rule");
          const review = el("button", "rw-button", "Review…");
          review.type = "button";
          review.addEventListener("click", () => { state.sheet = key; render(); });
          row.append(el("span", "", title), el("span", "rw-spacer"), el("em", "", mb(size)), review);
          reclaim.append(row);
        }
      }
      const trash = el("div", "rw-rule");
      const openTrash = el("button", "rw-button", "Open Trash");
      openTrash.type = "button";
      openTrash.addEventListener("click", () => toast("Open Trash shows it in Finder. Mactivity never empties it; you do, when you're sure."));
      trash.append(el("span", "", "In the Trash: 14 GB"), el("small", "", "Still using the space until the Trash is emptied."), el("span", "rw-spacer"), openTrash);
      reclaim.append(trash);
      return [volume, reclaim, wrap];
    },
    startup() {
      const groups = [
        ["Docker", "#1d8cf8", [["com.docker.helper", "Launch agent", "Running"], ["com.docker.vmnetd", "Daemon", "Running"]]],
        ["Dropbox", "#0061fe", [["Dropbox", "Login item", "Running"], ["com.dropbox.DropboxUpdater", "Launch agent", "Not running", "Unusual schedule"]]],
        ["Zoom", "#2d8cff", [["us.zoom.updater", "Launch agent", "Not running", "Points to a missing file"]]],
        ["Your own", "#8e8e93", [["com.me.backup", "Launch agent", "Running"]]],
      ];
      const table = card("rw-table");
      for (const [app, color, items] of groups) {
        const group = el("div", "rw-group");
        const badge = el("i", "rw-badge small", app[0]);
        badge.style.background = color;
        group.append(badge, el("b", "", app), el("small", "", `${items.length} item${items.length > 1 ? "s" : ""}`));
        table.append(group);
        for (const [name, kind, status, flag] of items) {
          const tr = el("div", "rw-tr four");
          tr.append(el("code", "", name), el("span", "muted", kind), el("span", status === "Running" ? "running" : "muted", status),
            flag ? el("span", "rw-flag", flag) : el("span"));
          table.append(tr);
        }
      }
      const intro = card("rw-note-card");
      intro.append(el("span", "", "What starts with your Mac, grouped by the app that put it there. Broken and unusual items are flagged."));
      // The last startup (D-171): how long the Mac took to settle, and who kept it busy.
      const login = card("rw-login");
      login.append(el("b", "", "Settled 6m after logging in"),
        el("small", "", "Last startup: Monday 9:02 AM · the processor averaged 41% over the first 10 minutes"),
        appChips([["Dropbox", "#0061fe", "52%", true], ["Docker", "#1d8cf8", "31%", true], ["Safari", "#1aa7ff", "12%"]],
          (name) => `${name}: its history opens from here. ⏻ marks apps that start with your Mac.`));
      return [intro, login, table];
    },
    alerts() {
      if (state.alertsTab === "rules") {
        const rules = [
          ["CPU", "An app uses more than 80% of a core for 5 minutes", true, "cpu"],
          ["Memory", "An app keeps growing past what it usually reaches", true, "memory"],
          ["Disk", "An app writes more than 1 GB in 10 minutes", true, "disk"],
          ["Network", "An app sends more than 500 MB in 10 minutes", false, "network"],
          ["New startup items", "Something adds itself to start with your Mac", true, "startup"],
          ["Data budget", "80% of the month's allowance used", false, "network"],
          ["Daily summary", "Yesterday's busiest apps, each morning", false, "history"],
        ];
        const list = card("rw-rules");
        for (const [name, text, on, glyph] of rules) {
          const row = el("div", "rw-rule");
          const g = badge(glyph, TINTS[glyph] || METRICS[glyph]?.color);
          const words = el("div");
          words.append(el("b", "", name), el("small", "", text));
          const toggle = el("button", `rw-switch${on ? " on" : ""}`);
          toggle.type = "button";
          toggle.setAttribute("role", "switch");
          toggle.setAttribute("aria-checked", String(on));
          toggle.setAttribute("aria-label", name);
          toggle.addEventListener("click", () => {
            const now = !toggle.classList.contains("on");
            toggle.classList.toggle("on", now);
            toggle.setAttribute("aria-checked", String(now));
          });
          row.append(g, words, el("span", "rw-spacer"), toggle);
          list.append(row);
        }
        const more = el("button", "rw-button rw-inline", "Thresholds, quiet hours, and muted apps…");
        more.type = "button";
        more.addEventListener("click", () => toast("Each rule's threshold, quiet hours, and apps you never want to hear about."));
        return [list, more];
      }
      // Recent (D-238): what went off, by day, newest first.
      const day = (ago) => new Date(Date.now() - ago * 86400000).toLocaleDateString("en-US", { weekday: "long", month: "short", day: "numeric" });
      const days = [
        ["Today", [["2:14 PM", "Slack's memory keeps climbing", "Up 1.4 GB in an hour, now 3.3 GB.", "memory"],
          ["11:42 AM", "Xcode is using a lot of CPU", "94% of a core for 6 minutes, building Mactivity.", "cpu"]]],
        ["Yesterday", [["4:05 PM", "Zoom now starts with your Mac", "It added us.zoom.updater, an agent that runs at login. Startup shows it, and can turn it off.", "startup"]]],
        [day(3), [["9:20 PM", "80% of your data budget used", "80 GB of 100 GB this month. It resets on the 1st.", "network"],
          ["10:03 AM", "Your Mac is running hot", "Slowed down to cool for 7 of the last 10 minutes.", "battery"]]],
      ];
      const nodes = [];
      for (const [title, items] of days) {
        nodes.push(sectionTitle(title));
        const list = card("rw-rules");
        for (const [time, head, body, glyph] of items) {
          const row = el("div", "rw-rule");
          const words = el("div");
          words.append(el("b", "", head), el("small", "", body));
          row.append(badge(glyph, TINTS[glyph] || METRICS[glyph]?.color), words, el("span", "rw-spacer"), el("small", "rw-time", time));
          list.append(row);
        }
        nodes.push(list);
      }
      return nodes;
    },
    // Devices (D-237): displays, ports and what's plugged in, as the app reads them.
    devices() {
      const head = card("rw-devices-head");
      const words = el("div");
      words.append(el("b", "", "2 external displays · 3 devices plugged in"),
        el("small", "", "This month: displays connected 86% of the time, lid closed 81%"));
      const settings = el("button", "rw-button", "Displays Settings…");
      settings.type = "button";
      settings.addEventListener("click", () => toast("Opens System Settings at Displays. Mactivity shows the settings; it doesn't change them."));
      head.append(words, el("span", "rw-spacer"), settings);
      const displays = card("rw-rules");
      for (const [name, main, panel, looks, hz, via] of [
        ["LG HDR 4K", true, "4K · 3840 × 2160 · 27-inch", "Looks like 2560 × 1440, scaled: sharp, at a little extra work for the graphics", "60 Hz", "Thunderbolt (USB-C 1)"],
        ["Dell U2723QE", false, "4K · 3840 × 2160 · 27-inch", "Looks like 1920 × 1080", "60 Hz", "HDMI"],
      ]) {
        const row = el("div", "rw-rule rw-display");
        const g = icon("display");
        g.style.color = TINTS.devices;
        const text = el("div");
        const title = el("b", "", name);
        if (main) title.append(el("span", "rw-tag", "Main"));
        text.append(title, el("small", "", panel), el("small", "", looks));
        const right = el("div", "rw-display-right");
        right.append(el("span", "", hz), el("small", "", via));
        row.append(g, text, el("span", "rw-spacer"), right);
        displays.append(row);
      }
      const lid = el("div", "rw-rule");
      lid.append(icon("laptop"), el("small", "", "The lid is closed: the Mac is running on its external displays."));
      displays.append(lid);
      const ports = card("rw-rules");
      for (const [port, what, on] of [["USB-C 1", "Display, Thunderbolt, and USB", true], ["USB-C 2", "Nothing plugged in", false],
        ["USB-C 3", "Power", true], ["HDMI", "Display", true], ["MagSafe", "Nothing plugged in", false]]) {
        const row = el("div", "rw-rule rw-port");
        row.append(el("b", "", port), el("span", on ? "" : "muted", what));
        ports.append(row);
      }
      const wired = card("rw-rules");
      for (const [name, maker, speed, tb] of [["TS4", "CalDigit, Inc.", "Up to 40 Gb/s", true],
        ["Magic Keyboard with Touch ID", "Apple Inc.", "12 Mb/s", false], ["USB Audio Device", "Focusrite", "480 Mb/s", false]]) {
        const row = el("div", "rw-rule");
        const text = el("div");
        text.append(el("b", "", name), el("small", "", maker));
        row.append(icon(tb ? "bolt" : "plug"), text, el("span", "rw-spacer"), el("small", "", speed));
        wired.append(row);
      }
      const pair = el("div", "rw-grid two");
      const left = el("div");
      left.append(sectionTitle("Ports"), ports);
      const right = el("div");
      right.append(sectionTitle("Plugged in"), wired);
      pair.append(left, right);
      return [head, sectionTitle("Displays"), displays, pair];
    },
    volume() {
      const list = card("rw-rules rw-audio");
      for (const app of AUDIO) {
        const row = el("div", "rw-rule");
        const badge = appBadge(app);
        const name = el("b", "rw-audio-name", app.name);
        const mute = el("button", `rw-icon-button${app.muted ? " muted" : ""}`);
        mute.type = "button";
        mute.setAttribute("aria-pressed", String(app.muted));
        mute.setAttribute("aria-label", `${app.muted ? "Unmute" : "Mute"} ${app.name}`);
        mute.append(icon(app.muted ? "muted" : "volume"));
        const slider = el("input", "rw-slider");
        slider.type = "range";
        slider.min = "0";
        slider.max = "100";
        slider.value = String(app.volume);
        slider.setAttribute("aria-label", `${app.name} volume`);
        const level = el("span", "rw-audio-level");
        const output = el("select", "rw-select");
        output.setAttribute("aria-label", `Where ${app.name} plays`);
        for (const name of OUTPUTS) {
          const option = el("option", "", name);
          option.selected = name === app.output;
          output.append(option);
        }
        const reset = el("button", "rw-icon-button");
        reset.type = "button";
        reset.setAttribute("aria-label", `Reset ${app.name}: 100%, unmuted, on the system default`);
        reset.title = `Back to 100%, unmuted, on the system default, and forget ${app.name}`;
        reset.append(icon("reset"));
        // Updated in place, so dragging the slider doesn't rebuild the row under the pointer.
        const show = () => {
          level.textContent = app.muted ? "Muted" : `${app.volume}%`;
          level.classList.toggle("muted", app.muted);
          slider.style.setProperty("--fill", `${app.muted ? 0 : app.volume}%`);
          slider.classList.toggle("muted", app.muted);
          reset.disabled = untouched(app);
        };
        slider.addEventListener("input", () => {
          app.volume = Number(slider.value);
          if (app.muted && app.volume > 0) {
            app.muted = false;
            mute.classList.remove("muted");
            mute.replaceChildren(icon("volume"));
            mute.setAttribute("aria-pressed", "false");
          }
          show();
        });
        mute.addEventListener("click", () => {
          app.muted = !app.muted;
          mute.classList.toggle("muted", app.muted);
          mute.replaceChildren(icon(app.muted ? "muted" : "volume"));
          mute.setAttribute("aria-pressed", String(app.muted));
          mute.setAttribute("aria-label", `${app.muted ? "Unmute" : "Mute"} ${app.name}`);
          show();
        });
        output.addEventListener("change", () => { app.output = output.value; show(); });
        reset.addEventListener("click", () => {
          Object.assign(app, { volume: 100, muted: false, output: "System default" });
          render();
        });
        show();
        row.append(badge, name, mute, slider, level, output, reset);
        list.append(row);
      }
      const footer = el("p", "rw-footnote",
        "Experimental. Level, mute, and output are remembered per app and come back whenever it plays. "
        + "An app at 100% on the system default plays untouched; Reset hands it back and forgets it.");
      return [sectionTitle("Apps playing audio"), list, footer];
    },
    history() {
      const nodes = [sectionTitle("Your day", "history", TINTS.history), yourDay()];
      for (const key of ["cpu", "gpu", "memory", "disk", "network"]) nodes.push(sectionTitle(METRICS[key].title, key, METRICS[key].color), historyStrip(key));
      return nodes;
    },
  };

  // Your day (D-191): today told as a timeline, from History.
  const DAY = [
    ["8:03 AM", "Woke up: Lid opened", "#ff9f0a", []],
    ["8:30 AM", "Unplugged at 100%", "#30d158", []],
    ["9:00 – 11:45 AM", "Claude Code in mactivity", "#ff9f0a", []],
    ["10:15 – 11:00 AM", "Busy, the processor up to 72%", "#2f7bff", [["Xcode", "#2f7bff"], ["Safari", "#1aa7ff"]]],
    ["2:10 – 2:45 PM", "Slowdown: Processor near full", "#ff9f0a", [["Xcode", "#2f7bff"], ["Google Chrome", "#4285f4"]]],
    ["3:41 PM", "Safari's memory keeps climbing ×3", "#ffd60a", []],
    ["4:30 PM", "Plugged in at 34%", "#30d158", []],
    ["7:00 – 9:00 PM", "Downloaded 9.4 GB", "#64d2ff", []],
  ];
  // Out of the ordinary (D-198): apps far past their own usual day on this Mac.
  const UNUSUAL = [
    ["Safari", "#0a84ff", "5.5 GB of memory today, 4× its usual 1.3 GB"],
    ["Docker", "#2496ed", "18% of the processor today; it's usually idle"],
  ];
  function unusualCard() {
    const wrap = card("rw-day");
    const head = el("div", "rw-unusual-head");
    head.append(el("b", "", "Out of the ordinary today"), el("small", "muted", "Compared with each app's usual day on this Mac"));
    wrap.append(head);
    for (const [name, color, text] of UNUSUAL) {
      const row = el("button", "rw-unusual-row");
      row.type = "button";
      row.append(appBadge({ name, color }, "rw-badge small"), el("b", "", name), el("span", "muted", text));
      row.addEventListener("click", () => toast(`Opens ${name}'s own history, with today beside its usual day.`));
      wrap.append(row);
    }
    return wrap;
  }

  function yourDay() {
    const wrap = card("rw-day");
    wrap.append(el("small", "muted", "Tuesday · 6h 12m in use"));
    for (const [time, title, color, apps] of DAY) {
      const row = el("div", "rw-day-row");
      const dot = el("i");
      dot.style.background = color;
      const words = el("span");
      words.append(el("span", "", title));
      if (apps.length) words.append(appChips(apps, (name) => `Opens ${name}'s own history.`));
      row.append(el("small", "muted", time), dot, words);
      wrap.append(row);
    }
    return wrap;
  }

  // Why is my Mac slow? (D-134): what the app says after watching for a few seconds.
  const SLOW = [
    ["The processor is 86% busy", "Using the most: Xcode, Google Chrome and Spotlight.", "Show"],
    ["Xcode is using 4.2 cores", "If it isn't doing something you asked for, quitting it frees them.", "Quit…"],
    ["Spotlight is indexing", "It catches up after updates and new files, then stops on its own.", ""],
    ["3.1 GB of memory is on the disk", "Memory ran short earlier. Apps that come back to it may pause for a moment.", "Show"],
  ];
  function slowSheet() {
    const sheet = el("div", "rw-sheet wide");
    sheet.setAttribute("role", "dialog");
    sheet.setAttribute("aria-label", "Why is my Mac slow?");
    sheet.append(el("b", "", "Why is my Mac slow?"), el("small", "", "What's slowing it now, most important first."));
    const list = el("div", "rw-clean-list");
    for (const [title, detail, action] of SLOW) {
      const row = el("div", "rw-clean-row");
      const words = el("span");
      words.append(el("span", "", title), el("small", "", detail));
      row.append(words);
      if (action) {
        const button = el("button", "rw-button", action);
        button.type = "button";
        button.addEventListener("click", () => {
          if (action === "Show") { state.sheet = null; select("cpu"); return; }
          toast("Quit… asks first, then quits the app. Nothing quits without your OK.");
        });
        row.append(button);
      }
      list.append(row);
    }
    // Slowdowns that already passed, from History (D-169).
    const earlier = el("div", "rw-earlier");
    earlier.append(el("b", "", "Slowdowns in the last 7 days"),
      el("small", "", "Times your Mac struggled, from History, with the apps busiest then."));
    for (const [title, when, apps] of EARLIER) {
      const row = el("div", "rw-earlier-row");
      row.append(el("span", "", title), el("small", "", when),
        appChips(apps, (name) => `Opens ${name}'s own history: its last 7, 30 or 90 days, and the hours of the week it works hardest.`));
      earlier.append(row);
    }
    const buttons = el("div");
    const done = el("button", "rw-button prominent", "Done");
    done.type = "button";
    done.addEventListener("click", () => { state.sheet = null; render(); });
    buttons.append(done);
    sheet.append(list, earlier, buttons);
    return sheet;
  }
  const EARLIER = [
    ["Processor near full", "Today, 2:10 – 2:45 PM · 35m", [["Xcode", "#2f7bff"], ["Safari", "#1aa7ff"], ["Terminal", "#3a3a3c"]]],
    ["Memory ran short", "Saturday, 2:10 – 2:55 PM · 45m", [["Safari", "#1aa7ff"], ["Code", "#0f7fd1"]]],
  ];

  // Apps open but unused (D-135).
  function unusedSheet() {
    const sheet = el("div", "rw-sheet wide");
    sheet.setAttribute("role", "dialog");
    sheet.setAttribute("aria-label", "Open but unused");
    sheet.append(el("b", "", "Open but unused"), el("small", "", "Apps you haven't used for days, still holding memory. Quitting frees it; they open again when you need them."));
    const list = el("div", "rw-clean-list");
    for (const [name, detail, size] of [["Docker Desktop", "Last used 7 days ago", "2.3 GB"], ["Keynote", "Not used since it opened: 12 days", "572 MB"]]) {
      const row = el("div", "rw-clean-row");
      const words = el("span");
      words.append(el("span", "", name), el("small", "", detail));
      const quit = el("button", "rw-button", "Quit…");
      quit.type = "button";
      quit.addEventListener("click", () => toast(`Quit… asks first, then quits ${name}.`));
      row.append(words, el("em", "", size), quit);
      list.append(row);
    }
    const buttons = el("div");
    const done = el("button", "rw-button prominent", "Done");
    done.type = "button";
    done.addEventListener("click", () => { state.sheet = null; render(); });
    buttons.append(done);
    sheet.append(list, buttons);
    return sheet;
  }

  // Quick Search (D-137): ⌃⌥M in the app; here, the toolbar's button or the same keys.
  function searchSheet() {
    const sheet = el("div", "rw-sheet wide");
    sheet.setAttribute("role", "dialog");
    sheet.setAttribute("aria-label", "Quick Search");
    const input = el("input", "rw-search-input");
    input.type = "search";
    input.placeholder = "Apps, processes, ports…  try “saf” or “:3000”";
    input.value = state.query || "";
    const list = el("div", "rw-clean-list");
    const fill = () => {
      const q = input.value.trim().toLowerCase();
      state.query = input.value;
      list.replaceChildren();
      const rows = [];
      if (!q || "why is my mac slow".includes(q)) rows.push(["Why is my Mac slow?", "", () => { state.sheet = "slow"; render(); }]);
      for (const app of APPS.filter((a) => a.id !== "macos")) {
        if (!q || app.name.toLowerCase().includes(q)) rows.push([app.name, `${app.cpu.toFixed(1)}% · ${app.mem.toFixed(1)} GB`, () => { state.sheet = null; select("cpu"); }]);
      }
      for (const [port, project] of [["3000", "ledger"], ["4321", "docs-site"], ["8000", "api"]]) {
        if (q && (":" + port).includes(q.startsWith(":") ? q : ":" + q)) rows.push([":" + port, project, () => { state.sheet = null; select("projects"); }]);
      }
      for (const [title, detail, go] of rows.slice(0, 8)) {
        const row = el("button", "rw-clean-row");
        row.type = "button";
        const words = el("span");
        words.append(el("span", "", title), el("small", "", detail));
        row.append(words);
        row.addEventListener("click", go);
        list.append(row);
      }
      if (!rows.length) list.append(el("small", "", "Nothing matches."));
    };
    input.addEventListener("input", fill);
    input.addEventListener("keydown", (e) => { if (e.key === "Escape") { state.sheet = null; render(); } });
    fill();
    sheet.append(input, list, el("small", "", "Return shows it in Mactivity · ⌘⌫ quits it · Esc closes"));
    setTimeout(() => input.focus({ preventScroll: true }), 0);
    return sheet;
  }

  function cleanupSheet(data) {
    const sheet = el("div", "rw-sheet wide");
    sheet.setAttribute("role", "dialog");
    sheet.setAttribute("aria-label", data.title);
    sheet.append(el("b", "", data.title), el("small", "", data.intro));
    const list = el("div", "rw-clean-list");
    const selected = () => data.rows.filter((r) => r[3]).reduce((m, r) => m + r[2], 0);
    const footer = el("small", "rw-clean-total");
    const move = el("button", "rw-button prominent", data.action || "Move to Trash…");
    const update = () => {
      footer.textContent = `Selected: ${mb(selected())}`;
      move.disabled = selected() === 0;
    };
    for (const row of data.rows) {
      const label = el("label", "rw-clean-row");
      const box = el("input");
      box.type = "checkbox";
      box.checked = row[3];
      box.addEventListener("change", () => { row[3] = box.checked; update(); });
      const words = el("span");
      words.append(el("span", "", row[0]), el("small", "", row[1]));
      label.append(box, words, el("em", "", mb(row[2])));
      list.append(label);
    }
    if (!data.rows.length) list.append(el("small", "", "Nothing left here."));
    const buttons = el("div");
    const done = el("button", "rw-button", "Done");
    done.type = move.type = "button";
    done.addEventListener("click", () => { state.sheet = null; render(); });
    move.addEventListener("click", () => {
      const freed = selected();
      data.rows = data.rows.filter((r) => !r[3]);
      state.sheet = null;
      toast(data.done ? data.done(mb(freed)) : `Moved ${mb(freed)} to the Trash. Empty the Trash to free the space.`);
    });
    update();
    buttons.append(done, move);
    sheet.append(list);
    if (data.note) sheet.append(el("small", "", data.note));
    sheet.append(footer, buttons);
    return sheet;
  }

  function toast(text) {
    state.toast = text;
    render();
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { state.toast = ""; render(); }, 3500);
  }

  function render() {
    for (const b of side.querySelectorAll(".rw-item")) {
      const on = b.dataset.key === state.selection;
      b.classList.toggle("on", on);
      b.setAttribute("aria-current", on ? "page" : "false");
    }
    renderToolbar();
    const scroll = content.scrollTop;
    const key = state.selection;
    const nodes = ORDER.includes(key) ? PAGES.metric(key) : PAGES[key]();
    content.replaceChildren(...nodes);
    if (state.confirm) {
      const sheet = el("div", "rw-sheet");
      sheet.setAttribute("role", "alertdialog");
      const agent = Array.isArray(state.confirm) ? null : state.confirm;
      const names = agent ? [`${agent.agent} in ${agent.project}`] : state.confirm;
      if (agent) {
        sheet.append(el("b", "", `Stop ${agent.agent} in ${agent.project}?`),
          el("small", "", `Processes it started: ${agent.count}. They're asked to stop, and stopped after 5 seconds if they don't. Work it hasn't saved is lost.`));
      } else {
        sheet.append(el("b", "", names.length === 1 ? `Stop “${names[0]}”?` : `Stop ${names.length} idle dev servers?`),
          el("small", "", names.length === 1 ? "Its port is freed. You can start it again from your terminal."
            : "Their ports are freed. You can start them again from your terminal."));
      }
      const buttons = el("div");
      const cancel = el("button", "rw-button", "Cancel");
      const stop = el("button", "rw-button prominent", "Stop");
      cancel.type = stop.type = "button";
      cancel.addEventListener("click", () => { state.confirm = null; render(); });
      stop.addEventListener("click", () => {
        names.forEach((n) => state.stopped.add(n));
        state.confirm = null;
        toast(agent ? `Stopped ${names[0]}.`
          : names.length === 1 ? `${names[0]} stopped. Its port is free.` : `${names.length} servers stopped. Their ports are free.`);
      });
      buttons.append(cancel, stop);
      sheet.append(buttons);
      content.append(sheet);
    }
    if (state.sheet === "slow") content.append(slowSheet());
    else if (state.sheet === "unused") content.append(unusedSheet());
    else if (state.sheet === "search") content.append(searchSheet());
    else if (state.sheet) content.append(cleanupSheet(CLEANUP[state.sheet]));
    if (state.toast) content.append(el("div", "rw-toast", state.toast));
    content.scrollTop = scroll;
  }

  render();
  // One update a second while the page is visible and the window is on screen.
  let visible = false;
  new IntersectionObserver((entries) => { visible = entries.some((e) => e.isIntersecting); }).observe(win);
  // Rebuilding the page mid-click would swallow the click, and mid-Tab would lose keyboard focus,
  // so updates wait while a pointer is down or the keyboard is moving through the window.
  let pressing = false;
  let keyboard = false;
  win.addEventListener("pointerdown", () => { pressing = true; keyboard = false; });
  addEventListener("pointerup", () => { pressing = false; });
  addEventListener("keydown", (event) => { if (event.key === "Tab") keyboard = true; });
  // ⌃⌥M opens Quick Search, as in the app, while the demo is on screen.
  addEventListener("keydown", (event) => {
    if (event.ctrlKey && event.altKey && event.code === "KeyM" && visible) {
      event.preventDefault();
      state.sheet = "search";
      render();
    }
  });
  setInterval(() => {
    if (document.hidden || !visible || state.confirm || state.sheet || state.cleanupMenu || pressing) return;
    if (keyboard && win.contains(document.activeElement)) return;
    // A slider or an open output menu would be replaced mid-use.
    if (win.contains(document.activeElement) && document.activeElement.matches("input, select")) return;
    tick();
    render();
  }, reduceMotion ? 4000 : 1000);
})();
