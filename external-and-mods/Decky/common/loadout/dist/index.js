const manifest = {"name":"Loadout"};
const API_VERSION = 2;
const internalAPIConnection = window.__DECKY_SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED_deckyLoaderAPIInit;
if (!internalAPIConnection) {
    throw new Error('[@decky/api]: Failed to connect to the loader as as the loader API was not initialized. This is likely a bug in Decky Loader.');
}
let api;
try {
    api = internalAPIConnection.connect(API_VERSION, manifest.name);
}
catch {
    api = internalAPIConnection.connect(1, manifest.name);
}
const callable = api.callable;
const toaster = api.toaster;
const routerHook = api.routerHook;
const pickFile = api.openFilePicker;
const definePlugin = (fn) => (...args) => fn(...args);

const DFL = window.DFL;
const SP_REACT = window.SP_REACT;
const SP_JSX = window.SP_JSX;
const { useEffect, useState, useCallback, useMemo } = SP_REACT;
const jsx = SP_JSX.jsx;
const jsxs = SP_JSX.jsxs;
const Frag = SP_JSX.Fragment;

// Every engine command (loadout.py), passed positionally to the Python side.
const E = {};
for (const n of ["status", "discover", "jobs", "install", "update", "remove", "cancel", "starter", "bundle",
    "bios", "check_updates", "update_all", "library", "reset", "sizes", "inspect", "add_game", "add_file",
    "art", "store_games", "add_store_game", "added", "remove_added", "compat_done", "desktop", "steam_pending", "steam_made",
    "steam_gone", "icon"]) E[n] = callable(n);

const ROUTE = "/loadout";
const CHIP_NAMES = { sm8350: "Snapdragon 888", sm8550: "Snapdragon 8 Gen 2", sm8650: "Snapdragon 8 Gen 3", sm8750: "Snapdragon 8 Elite" };
const PROTONS = [
    { data: "proton_experimental", label: "Proton Experimental" },
    { data: "proton_11", label: "Proton 11" },
];
// Loadout's own look: ink background, warm brass for what needs you,
// mint for ready, a soft violet for the store's accent.
const C = {
    ink: "#0b0f14", panel: "#131a22", raised: "#1a2430", line: "rgba(255,255,255,0.08)",
    text: "#e8edf2", dim: "rgba(232,237,242,0.62)", accent: "#a78bfa", accent2: "#7c5cf0",
    ready: "#6ee7b7", warn: "#f5c46a", bad: "#f87171",
};

// --------------------------------------------------------------- bits --
const iconCache = new Map();
function AppIcon({ path, size }) {
    const s = size || 40;
    const [src, setSrc] = useState(iconCache.get(path) || "");
    useEffect(() => {
        if (!path) return;
        if (iconCache.has(path)) { setSrc(iconCache.get(path)); return; }
        let live = true;
        E.icon(path).then((d) => { if (d) iconCache.set(path, d); if (live) setSrc(d || ""); }).catch(() => {});
        return () => { live = false; };
    }, [path]);
    const box = { width: `${s}px`, height: `${s}px`, borderRadius: `${Math.round(s / 4)}px`, flexShrink: 0 };
    return src ? jsx("img", { src, style: box })
        : jsx("div", { style: Object.assign({ background: `linear-gradient(135deg, ${C.accent2}55, ${C.raised})` }, box) });
}
const Pill = ({ text, color }) => text ? jsx("span", { style: {
    fontSize: "11px", padding: "2px 8px", borderRadius: "10px", whiteSpace: "nowrap",
    color: color || C.dim, background: (color || "#ffffff") + "1f", border: `1px solid ${(color || "#ffffff")}33` }, children: text }) : null;
const Small = ({ children, style }) => jsx("div", { style: Object.assign({ fontSize: "12px", color: C.dim, lineHeight: "17px" }, style || {}), children });
const H = ({ children }) => jsx("div", { style: { fontSize: "15px", fontWeight: 700, margin: "18px 0 10px", color: C.text, letterSpacing: "0.2px" }, children });
const row = (child) => jsx(DFL.PanelSectionRow, { children: child });

function stateOf(app) {
    if (app.job && app.job.state === "running") return { text: `${Math.round(app.job.pct || 0)}% · ${app.job.stage || "working"}`, color: C.accent };
    if (app.builtin) return { text: "Built in", color: C.ready };
    if (app.update) return { text: `Update ${app.update}`, color: C.warn };
    if (app.installed) return { text: app.version ? `Installed · ${app.version}` : "Installed", color: C.ready };
    if (app.elsewhere) return { text: "Installed from Discover", color: C.ready };
    if (!app.available) return { text: "Not for this device", color: C.dim };
    return null;
}
function fitOf(app, chip) {
    if (app.kind !== "emulator") return null;
    return app.heavy ? { text: "Demanding on this chip", color: C.warn } : { text: `Runs well on ${CHIP_NAMES[chip] || "this chip"}`, color: C.ready };
}

// Our own bar: Steam's progress widget is laid out for full-width pages.
function Bar({ job, onCancel }) {
    const pct = Math.max(0, Math.min(100, Math.round(job.pct || 0)));
    return jsxs("div", { style: { display: "flex", alignItems: "center", gap: "10px", width: "100%" }, children: [
        jsxs("div", { style: { flex: 1, minWidth: 0 }, children: [
            jsxs("div", { style: { display: "flex", justifyContent: "space-between", fontSize: "12px", color: C.dim, marginBottom: "4px" }, children: [
                jsx("span", { style: { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }, children: job.stage || "Working" }),
                jsx("span", { children: `${pct}%` }),
            ] }),
            jsx("div", { style: { height: "6px", borderRadius: "3px", background: C.line, overflow: "hidden" }, children:
                jsx("div", { style: { height: "100%", width: `${pct}%`, borderRadius: "3px", background: `linear-gradient(90deg, ${C.accent2}, ${C.accent})`, transition: "width 0.4s ease" } }) }),
        ] }),
        onCancel ? jsx(DFL.DialogButton, { style: { minWidth: 0, width: "44px", height: "30px", padding: 0, flexShrink: 0 }, onClick: onCancel, children: "✕" }) : null,
    ] });
}

// ------------------------------------------------------ Steam library --
// The engine queues a shortcut for everything it installs or adds; Steam's
// client API adds it at once (no Steam restart), sets Proton where the
// shortcut runs a Windows program, and puts store artwork on it.
let syncing = false;
const added = new Set();
async function putArt(appid, title) {
    try {
        const a = await E.art(title);
        if (!a || !a.found) return false;
        for (const x of a.assets || []) {
            try { await SteamClient.Apps.SetCustomArtworkForApp(appid, x.data, x.ext, x.type); } catch (e) {}
        }
        return true;
    } catch (e) { return false; }
}
async function syncShortcuts() {
    if (syncing || !window.SteamClient || !SteamClient.Apps) return;
    syncing = true;
    try {
        const p = await E.steam_pending();
        for (const s of (p && p.add) || []) {
            if (added.has(s.app)) continue;
            added.add(s.app);
            const appid = Number(await SteamClient.Apps.AddShortcut(s.name, s.exe, s.dir, s.options || ""));
            if (!appid) continue;
            try { SteamClient.Apps.SetShortcutName(appid, s.name); } catch (e) {}
            try { if (s.options) SteamClient.Apps.SetShortcutLaunchOptions(appid, s.options); } catch (e) {}
            try { if (s.icon) SteamClient.Apps.SetShortcutIcon(appid, s.icon); } catch (e) {}
            if (s.compat) {
                try { SteamClient.Apps.SpecifyCompatTool(appid, s.compat); } catch (e) {}
                if (s.app.startsWith("custom:")) await E.compat_done(s.app.slice(7));
            }
            await E.steam_made(s.app, appid);
            const withArt = s.art ? await putArt(appid, s.art) : false;
            toaster.toast({ title: s.name, body: withArt ? "In your Steam library, with its artwork" : "Added to your Steam library", duration: 2800 });
        }
        for (const c of (p && p.compat) || []) {
            try { SteamClient.Apps.SpecifyCompatTool(c.appid, c.tool); } catch (e) {}
            await E.compat_done(c.app.slice(7));
        }
        for (const r of (p && p.remove) || []) {
            try { SteamClient.Apps.RemoveShortcut(r.appid); } catch (e) {}
            await E.steam_gone(r.app);
        }
    } catch (e) {
        console.log("Loadout: shortcut sync", e);
    } finally {
        syncing = false;
    }
}
function play(appid) {
    const gameid = ((BigInt(appid >>> 0) << 32n) | 0x02000000n).toString();
    if (SteamClient.Apps.RunGame) SteamClient.Apps.RunGame(gameid, "", -1, 100);
    else SteamClient.URL.ExecuteSteamURL("steam://rungameid/" + gameid);
}

// Toast when a job ends, whoever started it and whether Loadout is open.
const seenJobs = {};
async function watchJobs() {
    try {
        const j = await E.jobs();
        for (const job of (j && j.jobs) || []) {
            const before = seenJobs[job.id];
            seenJobs[job.id] = job.state;
            if (before === "running" && job.state !== "running") {
                const verb = { install: "installed", update: "updated", remove: "removed" }[job.action] || "done";
                if (job.state === "done") toaster.toast({ title: job.app_title || job.app, body: `Ready: ${verb}`, duration: 3000 });
                else if (job.state === "failed") toaster.toast({ title: job.app_title || job.app, body: job.error || "Didn't work", duration: 6000, critical: true });
                if (job.state === "done") syncShortcuts();
            }
        }
    } catch (e) {}
}
// Games Heroic just finished installing: say once that they can go to Steam.
const seenStore = new Set();
let storeFirst = true;
async function watchStore() {
    try {
        const g = await E.store_games();
        const fresh = ((g && g.games) || []).filter((x) => !x.in_steam && !seenStore.has(`${x.store}:${x.id}`));
        fresh.forEach((x) => seenStore.add(`${x.store}:${x.id}`));
        if (!storeFirst && fresh.length) toaster.toast({ title: "Loadout", body: `${fresh.map((x) => x.title).join(", ")} can go in your Steam library (PC Games)`, duration: 6000 });
        storeFirst = false;
    } catch (e) {}
}

function useStatus(ms) {
    const [st, setSt] = useState(null);
    const refresh = useCallback(() => E.status().then((s) => { if (s && !s.error) setSt(s); }).catch(() => {}), []);
    useEffect(() => { refresh(); const t = setInterval(refresh, ms || 1500); return () => clearInterval(t); }, [refresh]);
    return [st, refresh];
}
const report = (r, fallback) => {
    if (r && r.error) toaster.toast({ title: "Loadout", body: r.error, critical: true, duration: 6000 });
    else if (fallback) toaster.toast({ title: "Loadout", body: fallback, duration: 2500 });
    return r;
};

// ------------------------------------------------------- app details --
function Details({ app, chip, closeModal, refresh }) {
    const [bios, setBios] = useState(null);
    const [size, setSize] = useState("");
    const [notes, setNotes] = useState(false);
    useEffect(() => {
        if (app.kind === "emulator") E.bios(app.id).then(setBios).catch(() => {});
        if (app.installed) E.sizes().then((s) => setSize(((s && s.sizes) || {})[app.id] || "")).catch(() => {});
    }, [app.id]);
    const st = stateOf(app);
    const fit = fitOf(app, chip);
    const job = app.job && app.job.state === "running" ? app.job : null;
    const done = (fn) => () => fn().then((r) => { report(r); refresh(); closeModal(); });
    const confirmRemove = () => DFL.showModal(jsx(DFL.ConfirmModal, {
        strTitle: `Remove ${app.title}?`,
        strDescription: "Your games, saves and settings stay. “Remove everything” clears its settings and saves too.",
        strOKButtonText: "Remove", strMiddleButtonText: "Remove everything", strCancelButtonText: "Keep",
        onOK: () => E.remove(app.id, false).then(refresh), onMiddleButton: () => E.remove(app.id, true).then(refresh),
    }));
    const confirmReset = () => DFL.showModal(jsx(DFL.ConfirmModal, {
        strTitle: `Reset ${app.title}'s settings?`,
        strDescription: "Back to how Loadout sets it up: controls, folders, paths. The old settings file is kept next to it; games and saves aren't touched.",
        strOKButtonText: "Reset", strCancelButtonText: "Keep",
        onOK: () => E.reset(app.id).then((r) => { report(r, "Settings reset"); refresh(); }),
    }));
    const buttons = [];
    if (job) buttons.push(jsx(Bar, { job, onCancel: () => E.cancel(job.id).then(refresh) }, "bar"));
    else if (app.builtin) { /* nothing to do */ }
    else if (app.installed) {
        if (app.steam_appid) buttons.push(jsx(DFL.DialogButton, { onClick: () => { closeModal(); play(app.steam_appid); }, children: app.kind === "emulator" ? "Open" : "Play" }, "play"));
        if (app.desktop_only) buttons.push(jsx(DFL.DialogButton, { onClick: () => E.desktop(), children: "Use in Desktop Mode" }, "desk"));
        if (app.update) buttons.push(jsx(DFL.DialogButton, { onClick: done(() => E.update(app.id)), children: `Update to ${app.update}` }, "upd"));
        if (app.resettable) buttons.push(jsx(DFL.DialogButton, { onClick: confirmReset, children: "Reset settings" }, "reset"));
        buttons.push(jsx(DFL.DialogButton, { onClick: confirmRemove, children: "Remove" }, "rm"));
    } else if (app.available) {
        buttons.push(jsx(DFL.DialogButton, { onClick: done(() => E.install(app.id)), children: app.elsewhere ? "Set up" : "Install" }, "inst"));
    }
    return jsx(DFL.ModalRoot, { onCancel: closeModal, closeModal, children: jsxs("div", { style: { color: C.text }, children: [
        jsxs("div", { style: { display: "flex", gap: "16px", alignItems: "center" }, children: [
            jsx(AppIcon, { path: app.icon, size: 72 }),
            jsxs("div", { style: { minWidth: 0 }, children: [
                jsx("div", { style: { fontSize: "22px", fontWeight: 700 }, children: app.title }),
                jsx(Small, { children: app.plays }),
                jsxs("div", { style: { display: "flex", gap: "6px", flexWrap: "wrap", marginTop: "8px" }, children: [
                    st ? jsx(Pill, st) : null, fit ? jsx(Pill, fit) : null, app.label ? jsx(Pill, { text: app.label }) : null,
                    size ? jsx(Pill, { text: size }) : null,
                ] }),
            ] }),
        ] }),
        app.note ? jsx(Small, { style: { marginTop: "14px" }, children: app.note }) : null,
        bios && bios.files && bios.files.length ? jsxs("div", { style: { marginTop: "14px", padding: "12px", borderRadius: "10px", background: C.panel }, children: [
            jsx("div", { style: { fontWeight: 600, marginBottom: "6px" }, children: bios.missing.length ? "Still needs" : "Has what it needs" }),
            ...bios.files.map((f) => jsxs("div", { style: { display: "flex", gap: "8px", fontSize: "13px", lineHeight: "22px" }, children: [
                jsx("span", { style: { color: f.found ? C.ready : (f.required ? C.warn : C.dim) }, children: f.found ? "✓" : "○" }),
                jsx("span", { children: f.label }),
                f.found ? jsx("span", { style: { color: C.dim }, children: `· ${f.found}` }) : null,
            ] }, f.label)),
            jsx(Small, { style: { marginTop: "6px" }, children: `Put them in ${bios.folder} (your own dumps; Loadout can't download them).` }),
        ] }) : null,
        app.update_notes ? jsxs("div", { style: { marginTop: "14px" }, children: [
            jsx(DFL.DialogButton, { onClick: () => setNotes(!notes), style: { width: "auto" }, children: notes ? "Hide what's new" : `What's new in ${app.update}` }),
            notes ? jsx("div", { style: { marginTop: "8px", maxHeight: "200px", overflowY: "auto", whiteSpace: "pre-wrap", fontSize: "12px", color: C.dim, padding: "10px", background: C.panel, borderRadius: "8px" }, children: app.update_notes.slice(0, 3000) }) : null,
        ] }) : null,
        buttons.length ? jsx(DFL.Focusable, { "flow-children": "horizontal", style: { display: "flex", gap: "10px", marginTop: "18px" },
            children: buttons.map((btn) => jsx("div", { style: { flex: "1 1 0", minWidth: 0 }, children: btn }, btn.key)) }) : null,
    ] }) });
}
const openDetails = (app, chip, refresh) => DFL.showModal(jsx(Details, { app, chip, refresh }));

// --------------------------------------------------------- the cards --
function Card({ app, chip, refresh }) {
    const st = stateOf(app);
    const fit = fitOf(app, chip);
    const job = app.job && app.job.state === "running" ? app.job : null;
    return jsx(DFL.DialogButton, {
        onClick: () => openDetails(app, chip, refresh),
        style: { display: "block", textAlign: "left", padding: "14px", minHeight: "118px", borderRadius: "12px",
            background: `linear-gradient(160deg, ${C.raised}, ${C.panel})`, border: `1px solid ${C.line}`, width: "100%" },
        children: jsxs("div", { children: [
            jsxs("div", { style: { display: "flex", gap: "12px", alignItems: "center" }, children: [
                jsx(AppIcon, { path: app.icon, size: 44 }),
                jsxs("div", { style: { minWidth: 0 }, children: [
                    jsx("div", { style: { fontSize: "15px", fontWeight: 700, color: C.text, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }, children: app.title }),
                    jsx(Small, { style: { display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden" }, children: app.plays }),
                ] }),
            ] }),
            jsx("div", { style: { marginTop: "10px" }, children: job ? jsx(Bar, { job })
                : jsxs("div", { style: { display: "flex", gap: "6px", flexWrap: "wrap" }, children: [
                    st ? jsx(Pill, st) : jsx(Pill, { text: "Get", color: C.accent }), app.heavy ? jsx(Pill, fit) : null,
                    app.bios ? jsx(Pill, { text: "Needs BIOS", color: C.warn }) : null,
                ] }) }),
        ] }),
    });
}
const Grid = ({ apps, chip, refresh }) => jsx(DFL.Focusable, {
    style: { display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(250px, 1fr))", gap: "12px" },
    children: apps.map((a) => jsx(Card, { app: a, chip, refresh }, a.id)) });

// ----------------------------------------------------------- for you --
function ForYou({ st, refresh }) {
    const [d, setD] = useState(null);
    const load = useCallback(() => E.discover().then((x) => { if (x && !x.error) setD(x); }).catch(() => {}), []);
    useEffect(() => { load(); const t = setInterval(load, 15000); return () => clearInterval(t); }, [load]);
    const chip = st.device.chip;
    const byId = Object.fromEntries(st.apps.map((a) => [a.id, a]));
    const total = d ? d.systems.reduce((n, s) => n + s.games, 0) : 0;
    const starterLeft = st.apps.filter((a) => a.starter && !a.installed && a.available && !(a.job && a.job.state === "running"));
    return jsxs("div", { children: [
        // the banner: what this device is and what its library holds
        jsxs("div", { style: { padding: "20px", borderRadius: "14px", background: `radial-gradient(120% 140% at 0% 0%, ${C.accent2}55, transparent 60%), linear-gradient(135deg, ${C.raised}, ${C.ink})`, border: `1px solid ${C.line}` }, children: [
            jsx("div", { style: { fontSize: "13px", color: C.accent, fontWeight: 600, letterSpacing: "1px", textTransform: "uppercase" }, children: `${st.device.model} · ${CHIP_NAMES[chip] || chip}` }),
            jsx("div", { style: { fontSize: "24px", fontWeight: 800, margin: "6px 0 4px" }, children: !d ? "Looking through your games…"
                : total ? `${total} games across ${d.systems.length} system${d.systems.length === 1 ? "" : "s"}` : "Your game library is empty" }),
            jsx(Small, { children: total ? `In ${d.library}/roms. Loadout picks emulators for what's there.`
                : `Put games in ${st.library}/roms/<system> (or move it to a card in Mine) and Loadout suggests what to get.` }),
            d && d.systems.length ? jsx("div", { style: { display: "flex", gap: "6px", flexWrap: "wrap", marginTop: "12px" }, children:
                d.systems.map((s) => jsx(Pill, { text: `${s.name} ${s.games}${s.ready ? (s.bios.length ? " · needs BIOS" : " ✓") : ""}`, color: s.ready ? (s.bios.length ? C.warn : C.ready) : C.accent }, s.system)) }) : null,
        ] }),
        d && d.suggestions.length ? jsxs(Frag, { children: [
            jsx(H, { children: "For the games you have" }),
            jsx(DFL.Focusable, { style: { display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(250px, 1fr))", gap: "12px" }, children:
                d.suggestions.map((s) => byId[s.app] ? jsx(DFL.DialogButton, {
                    onClick: () => E.install(s.app).then((r) => { report(r, `Installing ${s.title}`); refresh(); }),
                    style: { textAlign: "left", padding: "14px", borderRadius: "12px", background: `linear-gradient(160deg, ${C.accent2}33, ${C.panel})`, border: `1px solid ${C.accent}44` },
                    children: jsxs("div", { style: { display: "flex", gap: "12px", alignItems: "center" }, children: [
                        jsx(AppIcon, { path: byId[s.app].icon, size: 44 }),
                        jsxs("div", { children: [
                            jsx("div", { style: { fontWeight: 700, color: C.text }, children: `Get ${s.title}` }),
                            jsx(Small, { children: `${s.games} ${s.systems.join(" + ")} game${s.games === 1 ? "" : "s"} waiting` }),
                        ] }),
                    ] }) }, s.app) : null) }),
        ] }) : null,
        starterLeft.length ? jsxs(Frag, { children: [
            jsx(H, { children: "Starter set for this chip" }),
            jsx(DFL.DialogButton, { onClick: () => E.starter().then((r) => { report(r, "Installing the starter set"); refresh(); }),
                children: `Install ${starterLeft.length}: ${starterLeft.map((a) => a.title).join(", ")}` }),
        ] }) : null,
        d && d.bundles.length ? jsxs(Frag, { children: [
            jsx(H, { children: "Sets" }),
            jsx(DFL.Focusable, { style: { display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(250px, 1fr))", gap: "12px" }, children:
                d.bundles.map((b) => jsx(DFL.DialogButton, {
                    disabled: !b.missing.length,
                    onClick: () => E.bundle(b.id).then((r) => { report(r, `Installing ${b.title}`); refresh(); }),
                    style: { textAlign: "left", padding: "14px", borderRadius: "12px", background: C.panel, border: `1px solid ${C.line}`, minHeight: "120px" },
                    children: jsxs("div", { children: [
                        jsx("div", { style: { fontWeight: 700, color: C.text }, children: b.title }),
                        jsx(Small, { style: { margin: "4px 0 10px" }, children: b.about }),
                        jsxs("div", { style: { display: "flex", gap: "6px", alignItems: "center" }, children: [
                            jsx("div", { style: { display: "flex" }, children: b.apps.slice(0, 5).map((id, i) => jsx("div", { style: { marginLeft: i ? "-8px" : 0 }, children: jsx(AppIcon, { path: (byId[id] || {}).icon, size: 26 }) }, id)) }),
                            jsx(Pill, b.missing.length ? { text: `Get ${b.missing.length}`, color: C.accent } : { text: "All installed", color: C.ready }),
                        ] }),
                    ] }) }, b.id)) }),
        ] }) : null,
    ] });
}

// ---------------------------------------------------------- PC games --
function PcGames({ st, refresh }) {
    const [g, setG] = useState(null);
    const load = useCallback(() => E.store_games().then((x) => { if (x && !x.error) setG(x); }).catch(() => {}), []);
    useEffect(() => { load(); const t = setInterval(load, 8000); return () => clearInterval(t); }, [load]);
    const chip = st.device.chip;
    const stores = st.apps.filter((a) => a.kind === "store");
    const heroic = st.apps.find((a) => a.id === "heroic");
    const waiting = g ? g.games.filter((x) => !x.in_steam) : [];
    const addOne = (x) => E.add_store_game(x.store, x.id).then((r) => { report(r); syncShortcuts(); load(); });
    return jsxs("div", { children: [
        jsxs("div", { style: { padding: "16px", borderRadius: "14px", background: C.panel, border: `1px solid ${C.line}`, marginBottom: "14px" }, children: [
            jsx("div", { style: { fontWeight: 700, fontSize: "16px" }, children: "Your Epic, GOG and Amazon games, in Steam" }),
            jsx(Small, { style: { marginTop: "6px" }, children:
                "1. Install Heroic below and sign in to your stores.  2. Install games in Heroic.  3. They show up here: add them and they play from your Steam library with Steam's own Proton, artwork included." }),
        ] }),
        jsx(Grid, { apps: stores, chip, refresh }),
        heroic && heroic.installed ? jsxs(Frag, { children: [
            jsx(H, { children: g && g.games.length ? `Installed in Heroic · ${g.games.length}` : "Installed in Heroic" }),
            !g ? jsx(Small, { children: "Looking…" })
                : !g.games.length ? jsx(Small, { children: "Nothing yet. Games you install in Heroic appear here." })
                : jsxs(DFL.Focusable, { children: [
                    waiting.length > 1 ? jsx(DFL.DialogButton, { style: { marginBottom: "10px" }, onClick: () => Promise.all(waiting.map(addOne)), children: `Add all ${waiting.length} to Steam` }) : null,
                    ...g.games.map((x) => jsxs("div", { style: { display: "flex", alignItems: "center", gap: "12px", padding: "10px 12px", borderRadius: "10px", background: C.panel, marginBottom: "8px" }, children: [
                        jsxs("div", { style: { flex: 1, minWidth: 0 }, children: [
                            jsx("div", { style: { fontWeight: 600 }, children: x.title }),
                            jsx(Small, { children: `${{ epic: "Epic Games", gog: "GOG", amazon: "Amazon Games" }[x.store]} · ${x.windows ? "Windows game, runs with Proton" : "native"}` }),
                        ] }),
                        x.in_steam ? jsx(Pill, { text: "In Steam", color: C.ready })
                            : jsx(DFL.DialogButton, { style: { width: "auto", minWidth: "140px" }, onClick: () => addOne(x), children: "Add to Steam" }),
                    ] }, `${x.store}:${x.id}`)),
                ] }),
        ] }) : null,
    ] });
}

// --------------------------------------------------------- add a game --
function AddGame({ info, closeModal, refresh }) {
    const [name, setName] = useState(info.name);
    const [choice, setChoice] = useState(info.choices && info.choices[0] ? info.choices[0].app : "");
    const [proton, setProton] = useState(info.proton || "proton_experimental");
    const [busy, setBusy] = useState(false);
    const kinds = { windows: "Windows game or app", linux: "Linux program", rom: "Console game", apk: "Android app" };
    const go = () => {
        setBusy(true);
        E.add_game(info.path, info.as, name, choice, info.as === "windows" ? proton : "").then((r) => {
            setBusy(false);
            if (r && r.error) { report(r); return; }
            if (r && r.android) toaster.toast({ title: name, body: "Installing into Android; it gets its own Steam title", duration: 4000 });
            else syncShortcuts();
            refresh && refresh();
            closeModal();
        });
    };
    return jsx(DFL.ModalRoot, { onCancel: closeModal, closeModal, children: jsxs("div", { style: { color: C.text }, children: [
        jsx("div", { style: { fontSize: "20px", fontWeight: 700 }, children: info.as ? `Add to Steam: ${kinds[info.as]}` : "Can't add this" }),
        jsx(Small, { style: { margin: "4px 0 12px", wordBreak: "break-all" }, children: info.path }),
        info.as ? jsx(DFL.TextField, { label: "Name in your library", value: name, onChange: (e) => setName(e.target.value) }) : null,
        info.as === "rom" && info.choices.length > 1 ? jsx(DFL.DropdownItem, {
            label: "System", rgOptions: info.choices.map((c) => ({ data: c.app, label: `${c.name} (${c.app_title}${c.installed ? "" : ", gets installed"})` })),
            selectedOption: choice, onChange: (o) => setChoice(o.data) }) : null,
        info.as === "windows" ? jsx(DFL.DropdownItem, { label: "Runs with", rgOptions: PROTONS, selectedOption: proton, onChange: (o) => setProton(o.data) }) : null,
        info.note ? jsx(Small, { style: { marginTop: "10px" }, children: info.note }) : null,
        info.as && info.as !== "apk" ? jsx(Small, { style: { marginTop: "6px" }, children: "Artwork comes from the Steam store when the game is sold there." }) : null,
        info.as ? jsx(DFL.DialogButton, { disabled: busy || !name.trim(), style: { marginTop: "16px" }, onClick: go, children: busy ? "Adding…" : "Add to Steam" }) : null,
    ] }) });
}
async function addAGame(refresh) {
    try {
        const picked = await pickFile(0, "/home/steamos", true, true, undefined, undefined, false, false);
        const path = picked && (picked.realpath || picked.path);
        if (!path) return;
        const info = await E.inspect(path);
        if (info && info.error) { report(info); return; }
        DFL.showModal(jsx(AddGame, { info, refresh }));
    } catch (e) { /* closed the picker */ }
}

// --------------------------------------------------------------- mine --
const KIND_NAMES = { windows: "Windows · Proton", linux: "Linux", rom: "Console game", store: "From Heroic" };
function Added({ refresh }) {
    const [g, setG] = useState(null);
    const load = useCallback(() => E.added().then((x) => { if (x && !x.error) setG(x.games || []); }).catch(() => {}), []);
    useEffect(() => { load(); const t = setInterval(load, 5000); return () => clearInterval(t); }, [load]);
    if (!g || !g.length) return null;
    const take = (x) => DFL.showModal(jsx(DFL.ConfirmModal, {
        strTitle: `Take ${x.name} out of Steam?`,
        strDescription: "Only the Steam entry goes; the game's files stay where they are.",
        strOKButtonText: "Take out", strCancelButtonText: "Keep",
        onOK: () => E.remove_added(x.key).then(() => { syncShortcuts(); load(); }),
    }));
    return jsxs(Frag, { children: [
        jsx(H, { children: `Added by you · ${g.length}` }),
        jsx(DFL.Focusable, { children: g.map((x) => jsxs("div", { style: { display: "flex", alignItems: "center", gap: "12px", padding: "10px 12px", borderRadius: "10px", background: C.panel, marginBottom: "8px" }, children: [
            jsxs("div", { style: { flex: 1, minWidth: 0 }, children: [
                jsx("div", { style: { fontWeight: 600 }, children: x.name }),
                jsx(Small, { style: { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }, children: `${KIND_NAMES[x.kind] || ""} · ${x.path}` }),
            ] }),
            x.appid ? jsx(DFL.DialogButton, { style: { width: "auto", minWidth: "90px" }, onClick: () => play(x.appid), children: "Play" }) : jsx(Pill, { text: "Adding…", color: C.accent }),
            jsx(DFL.DialogButton, { style: { width: "auto", minWidth: "120px" }, onClick: () => take(x), children: "Take out" }),
        ] }, x.key)) }),
    ] });
}

function Mine({ st, refresh }) {
    const [sizes, setSizes] = useState({});
    const [busy, setBusy] = useState("");
    useEffect(() => { E.sizes().then((s) => setSizes((s && s.sizes) || {})).catch(() => {}); }, [st.apps.filter((a) => a.installed).length]);
    const chip = st.device.chip;
    const mine = st.apps.filter((a) => a.installed && !a.builtin);
    const updates = mine.filter((a) => a.update);
    const onSd = (st.sd || []).some((m) => st.library.startsWith(m));
    const work = (label, fn) => () => { setBusy(label); fn().then((r) => {
        report(r);
        if (r && r.updates) toaster.toast({ title: "Loadout", body: Object.keys(r.updates).length ? `${Object.keys(r.updates).length} update(s) ready` : "Everything is up to date" });
    }).finally(() => { setBusy(""); refresh(); }); };
    return jsxs("div", { children: [
        jsxs(DFL.Focusable, { style: { display: "grid", gridTemplateColumns: "1fr 1fr", gap: "12px" }, children: [
            jsx(DFL.DialogButton, { onClick: () => addAGame(refresh), style: { padding: "16px", textAlign: "left", borderRadius: "12px", background: `linear-gradient(160deg, ${C.accent2}44, ${C.panel})` },
                children: jsxs("div", { children: [jsx("div", { style: { fontWeight: 700, fontSize: "16px", color: C.text }, children: "＋ Add a game or app" }),
                    jsx(Small, { children: "A Windows .exe, a Linux program or AppImage, a console game file or an Android .apk: Loadout works out how it runs and puts it in Steam." })] }) }),
            jsx(DFL.DialogButton, { onClick: updates.length ? work("upd", E.update_all) : work("chk", E.check_updates), style: { padding: "16px", textAlign: "left", borderRadius: "12px" },
                children: jsxs("div", { children: [jsx("div", { style: { fontWeight: 700, fontSize: "16px", color: C.text }, children: busy === "chk" ? "Checking…" : updates.length ? `Update all (${updates.length})` : "Check for updates" }),
                    jsx(Small, { children: updates.length ? updates.map((a) => `${a.title} ${a.update}`).join(", ") : "Every app is checked against its own releases." })] }) }),
        ] }),
        jsx(Added, { refresh }),
        jsx(H, { children: `Installed · ${mine.length}` }),
        mine.length ? jsx(Grid, { apps: mine.map((a) => Object.assign({}, a, { plays: sizes[a.id] ? `${a.plays} · ${sizes[a.id]}` : a.plays })), chip, refresh }) : jsx(Small, { children: "Nothing yet." }),
        (st.found || []).length ? jsxs(Frag, { children: [
            jsx(H, { children: "AppImages found on this device" }),
            ...st.found.map((f) => jsxs("div", { style: { display: "flex", alignItems: "center", gap: "12px", padding: "10px 12px", borderRadius: "10px", background: C.panel, marginBottom: "8px" }, children: [
                jsxs("div", { style: { flex: 1, minWidth: 0 }, children: [jsx("div", { style: { fontWeight: 600 }, children: f.name }), jsx(Small, { children: f.path })] }),
                f.added ? jsx(Pill, { text: "In Steam", color: C.ready }) : jsx(DFL.DialogButton, { style: { width: "auto" }, onClick: () => E.add_file(f.path).then(() => { syncShortcuts(); refresh(); }), children: "Add to Steam" }),
            ] }, f.key)),
        ] }) : null,
        jsx(H, { children: "Game library" }),
        jsx(Small, { children: st.library }),
        jsx(DFL.DropdownItem, {
            label: "Keep games on",
            rgOptions: [{ data: "internal", label: st.home_label || "Internal storage" }].concat((st.sd || []).length ? [{ data: "sd", label: "SD card" }] : []),
            selectedOption: onSd ? "sd" : "internal",
            onChange: (o) => work("lib", () => E.library(o.data))(),
        }),
        jsx(Small, { children: "Moving the library brings your games along and points every emulator at the new place. Games go in roms/<system>, BIOS files in bios/." }),
    ] });
}

// --------------------------------------------------------------- page --
const TABS = [
    { id: "foryou", title: "For You" },
    { id: "emulators", title: "Emulators", kinds: ["emulator", "frontend"] },
    { id: "pc", title: "PC Games" },
    { id: "apps", title: "Apps", kinds: ["app", "media", "browser"] },
    { id: "tools", title: "Tools", kinds: ["tool", "plugin"] },
    { id: "mine", title: "Mine" },
];
function Page() {
    const [st, refresh] = useStatus(1500);
    const [tab, setTab] = useState("foryou");
    const [q, setQ] = useState("");
    if (!st) return jsx("div", { style: { paddingTop: "60px", textAlign: "center", color: C.dim }, children: "Loadout is looking at this device…" });
    const chip = st.device.chip;
    const hits = q.trim() ? st.apps.filter((a) => (a.title + " " + a.plays).toLowerCase().includes(q.trim().toLowerCase())) : null;
    const body = (t) => {
        if (t.id === "foryou") return jsx(ForYou, { st, refresh });
        if (t.id === "pc") return jsx(PcGames, { st, refresh });
        if (t.id === "mine") return jsx(Mine, { st, refresh });
        return jsx(Grid, { apps: st.apps.filter((a) => t.kinds.includes(a.kind)), chip, refresh });
    };
    const wrap = (child) => jsx("div", { style: { padding: "4px 24px 40px", color: C.text }, children: child });
    return jsxs("div", { style: { marginTop: "40px", height: "calc(100% - 40px)", background: C.ink, display: "flex", flexDirection: "column" }, children: [
        jsxs("div", { style: { display: "flex", alignItems: "center", gap: "16px", padding: "14px 24px 6px" }, children: [
            jsx("div", { style: { fontSize: "22px", fontWeight: 800, color: C.text }, children: "Loadout" }),
            jsx("div", { style: { flex: 1 }, children: jsx(DFL.TextField, { placeholder: "Search apps and emulators", value: q, onChange: (e) => setQ(e.target.value) }) }),
        ] }),
        hits ? jsx("div", { style: { flex: 1, overflowY: "auto" }, children: wrap(hits.length ? jsx(Grid, { apps: hits, chip, refresh }) : jsx(Small, { children: "Nothing matches." })) })
            : jsx("div", { style: { flex: 1, minHeight: 0 }, children: jsx(DFL.Tabs, {
                activeTab: tab, onShowTab: (id) => setTab(id), autoFocusContents: true,
                tabs: TABS.map((t) => ({ id: t.id, title: t.title, content: wrap(body(t)) })),
            }) }),
    ] });
}

// -------------------------------------------------------- quick access --
function Panel() {
    const [st, refresh] = useStatus(2000);
    const open = (tab) => { DFL.Navigation.CloseSideMenus(); DFL.Navigation.Navigate(ROUTE); };
    if (!st) return jsx(DFL.PanelSection, { children: row("Looking at this device…") });
    const running = st.apps.filter((a) => a.job && a.job.state === "running");
    const updates = st.apps.filter((a) => a.update);
    return jsxs(Frag, { children: [
        jsxs(DFL.PanelSection, { children: [
            row(jsx(DFL.ButtonItem, { layout: "below", onClick: open, description: "Emulators, PC game stores and apps for this device", children: "Open Loadout" })),
            row(jsx(DFL.ButtonItem, { layout: "below", onClick: () => addAGame(refresh), description: ".exe, AppImage, console game or .apk", children: "Add a game to Steam" })),
            updates.length ? row(jsx(DFL.ButtonItem, { layout: "below", onClick: () => E.update_all().then(refresh), description: updates.map((a) => a.title).join(", "), children: `Update all (${updates.length})` })) : null,
        ] }),
        running.length ? jsx(DFL.PanelSection, { title: "Working", children: running.map((a) => row(jsx(DFL.Field, {
            label: a.title, childrenLayout: "below", bottomSeparator: "none",
            children: jsx(Bar, { job: a.job, onCancel: () => E.cancel(a.job.id).then(refresh) }) }, a.id))) }) : null,
        row(jsx(Small, { children: `${st.device.model} · ${CHIP_NAMES[st.device.chip] || st.device.chip}` })),
    ] });
}

var index = definePlugin(() => {
    routerHook.addRoute(ROUTE, Page, { exact: true });
    syncShortcuts();
    watchStore();
    const t1 = setInterval(syncShortcuts, 5000);
    const t2 = setInterval(watchJobs, 3000);
    const t3 = setInterval(watchStore, 60000);
    return {
        name: "Loadout",
        titleView: jsx("div", { className: DFL.staticClasses && DFL.staticClasses.Title, children: "Loadout" }),
        content: jsx(Panel, {}),
        // a loadout slot: a case with two cartridges in it
        icon: jsx("svg", { viewBox: "0 0 24 24", width: "1em", height: "1em", fill: "currentColor", children: [
            jsx("path", { d: "M4 7.5A2.5 2.5 0 0 1 6.5 5h11A2.5 2.5 0 0 1 20 7.5v9a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5v-9zm2.5-.5a.5.5 0 0 0-.5.5v9a.5.5 0 0 0 .5.5h11a.5.5 0 0 0 .5-.5v-9a.5.5 0 0 0-.5-.5h-11z" }, "case"),
            jsx("rect", { x: "7.5", y: "8.5", width: "3.5", height: "7", rx: "0.8" }, "a"),
            jsx("rect", { x: "13", y: "8.5", width: "3.5", height: "7", rx: "0.8" }, "b"),
        ] }),
        alwaysRender: false,
        onDismount() {
            clearInterval(t1); clearInterval(t2); clearInterval(t3);
            routerHook.removeRoute(ROUTE);
        },
    };
});

export { index as default };
