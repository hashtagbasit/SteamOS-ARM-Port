const manifest = {"name":"Handheld Control"};
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
const definePlugin = (fn) => (...args) => fn(...args);

const DFL = window.DFL;
const SP_REACT = window.SP_REACT;
const SP_JSX = window.SP_JSX;
const { useEffect, useState, useCallback, useRef } = SP_REACT;
const jsx = SP_JSX.jsx;
const jsxs = SP_JSX.jsxs;

// Decky callable(): arguments are passed positionally to the Python method.
const getState = callable("get_state");
const setProfile = callable("set_profile");
const setRgb = callable("set_rgb");
const setMcu = callable("set_mcu");
const setFan = callable("set_fan");
const setPowerLed = callable("set_power_led");
const setMenuClicks = callable("set_menu_clicks");
const setBypass = callable("set_bypass");
const setButton = callable("set_button");
const setGameFan = callable("set_game_fan");
const GAME_FAN_OPTIONS = [
    { data: "global", label: "Same as above" },
    { data: "silent", label: "Quiet curve" },
    { data: "balanced", label: "Balanced curve" },
    { data: "turbo", label: "Cool curve" },
    { data: "fixed-40", label: "Fixed 40%" },
    { data: "fixed-60", label: "Fixed 60%" },
    { data: "fixed-80", label: "Fixed 80%" },
    { data: "fixed-100", label: "Fixed 100%" },
];
function gameName(appid) {
    try {
        const o = window.appStore && window.appStore.GetAppOverviewByAppID(appid);
        if (o && o.display_name) return o.display_name;
    } catch (e) {}
    return `App ${appid}`;
}
const BUTTON_ACTIONS = [
    { data: "profile-next", label: "Next performance profile" },
    { data: "rgb-next", label: "Next stick lighting" },
    { data: "sticks-toggle", label: "Stick lights on/off" },
    { data: "fan-boost", label: "Fan boost" },
    { data: "game", label: "Game button (bind in Steam)" },
    { data: "none", label: "Nothing" },
];

const PROFILES = [
    { data: "silent", label: "Silent", desc: "Quiet fan, GPU capped at 75%, no game boost" },
    { data: "balanced", label: "Balanced", desc: "Full clocks on demand, game threads on the big cores" },
    { data: "turbo", label: "Turbo", desc: "Big cores held high, GPU floor raised, fan aggressive" },
];
const RGB_PRESETS = [
    { label: "Ember", mode: "static", color: "ff3c00" },
    { label: "Ice", mode: "static", color: "00b4ff" },
    { label: "Violet", mode: "static", color: "a000ff" },
    { label: "White", mode: "static", color: "ffffff" },
    { label: "Breathe", mode: "breath", color: "ff0040" },
    { label: "Off", mode: "off", color: "000000" },
];


const row = (child) => jsx(DFL.PanelSectionRow, { children: child });
const note = (text) => row(jsx("div", { style: { fontSize: "12px", opacity: 0.75 }, children: text }));


// Short frame limit list. Steam offers every whole fraction of every refresh
// rate down to 12 (Pocket FIT: 12 15 18 20 24 30 36 40 45 48 60 72 90 120
// 144). It reads them from its GamescopeService state in the UI's query
// cache, so the copy there is trimmed to 30 plus the panel's refresh rates
// (Pocket FIT 30/60/90/120/144, RP6 30/60/120). Only entries are removed; the
// limiter is still Steam's. If the cache can't be found nothing changes.
const SHORT_FPS_KEY = "steamos-arm:short-fps-list";
const GS_STATE = ["GamescopeService", "State"];
let shortFpsUnsub = null;
let queryClient = null;
function shortFpsWanted() {
    try { return localStorage.getItem(SHORT_FPS_KEY) !== "0"; } catch (e) { return true; }
}
function findQueryClient() {
    if (queryClient) return queryClient;
    try {
        // Decky's module search: Steam's loader doesn't expose its module cache.
        // By shape only: the GamescopeService entry is only filled once
        // something asks for it, and the subscription catches that.
        queryClient = DFL.findModuleExport((e) => e && typeof e.getQueryData === "function"
            && typeof e.getQueryCache === "function" && typeof e.setQueryData === "function"
            && typeof e.invalidateQueries === "function") || null;
    } catch (e) { console.log("Handheld Control: query cache", e); }
    return queryClient;
}
function trimFrameRates(d) {
    const adi = d && d.active_display_info;
    const fr = adi && adi.supported_frame_rates, rr = adi && adi.supported_refresh_rates;
    if (!Array.isArray(fr) || !Array.isArray(rr) || rr.length === 0) return null;
    const keep = new Set(rr);
    if (rr.some((r) => r % 30 === 0)) keep.add(30);
    const out = fr.filter((v) => keep.has(v));
    if (out.length === 0 || out.length === fr.length) return null;
    return { ...d, active_display_info: { ...adi, supported_frame_rates: out } };
}
// What the short list holds on this screen, for the toggle's description.
function shortFpsSteps() {
    const qc = findQueryClient();
    const adi = qc && qc.getQueryData(GS_STATE) && qc.getQueryData(GS_STATE).active_display_info;
    const rr = adi && Array.isArray(adi.supported_refresh_rates) ? [...adi.supported_refresh_rates] : [];
    if (rr.some((r) => r % 30 === 0) && !rr.includes(30)) rr.push(30);
    rr.sort((a, b) => a - b);
    return rr.length ? rr.join(" / ") : "30 / 60 / 90 / 120";
}
function applyShortFps(on) {
    if (shortFpsUnsub) { shortFpsUnsub(); shortFpsUnsub = null; }
    const qc = findQueryClient();
    if (!qc) return false;
    if (!on) { qc.invalidateQueries({ queryKey: GS_STATE }); return true; }
    const apply = () => { const t = trimFrameRates(qc.getQueryData(GS_STATE)); if (t) qc.setQueryData(GS_STATE, t); };
    shortFpsUnsub = qc.getQueryCache().subscribe((ev) => {
        const key = ev && ev.query && ev.query.queryKey;
        if (ev && ev.type === "updated" && key && key[0] === GS_STATE[0] && key[1] === GS_STATE[1]) apply();
    });
    apply();
    return true;
}
const EVO_MODES = [
    { data: "default", label: "Default" },
    { data: "breath", label: "Breath – Single" },
    { data: "rgb-cycle", label: "Breath – RGB" },
    { data: "google", label: "Breath – Google" },
    { data: "static", label: "Static" },
    { data: "follow", label: "Reactive" },
    { data: "off", label: "Off" },
];
function EvoLighting({ st, refresh }) {
    const complete = (rgb) => ({ secondary_color: "0000ff", speed: 1, ...rgb });
    const [cfg, setCfg] = useState(() => complete(st.rgb));
    const current = useRef(cfg);
    const pending = useRef([]);
    const saved = useRef({ ...st.rgb_presets, [cfg.mode]: cfg });
    const [customize, setCustomize] = useState(false);
    const timer = useRef(null);
    const saving = useRef(false);
    const mounted = useRef(true);
    const flush = async () => {
        if (saving.current || !pending.current.length) return;
        saving.current = true;
        try {
            while (pending.current.length) {
                const c = pending.current.shift();
                try {
                    await setRgb(c.mode, c.color, c.brightness, c.secondary_color, c.speed);
                } catch (e) {
                    toaster.toast({ title: "Pocket EVO lighting", body: String(e) });
                }
            }
        } finally {
            saving.current = false;
            if (mounted.current) refresh();
        }
    };
    useEffect(() => {
        if (pending.current.length || saving.current) return;
        const c = complete(st.rgb);
        current.current = c;
        saved.current = { ...st.rgb_presets, [c.mode]: c };
        setCfg(c);
    }, [JSON.stringify(st.rgb), JSON.stringify(st.rgb_presets)]);
    useEffect(() => {
        mounted.current = true;
        return () => {
            mounted.current = false;
            clearTimeout(timer.current);
            flush();
        };
    }, []);
    const change = (patch) => {
        const c = { ...current.current, ...patch };
        current.current = c;
        saved.current[c.mode] = c;
        const queue = pending.current;
        if (queue.length && queue[queue.length - 1].mode === c.mode) queue[queue.length - 1] = c;
        else queue.push(c);
        setCfg(c);
        clearTimeout(timer.current);
        timer.current = setTimeout(flush, 150);
    };
    const colorSliders = (key, title) => {
        const color = cfg[key] || "000000";
        return [
            note(`${title}: #${color.toUpperCase()}`),
            ...["Red", "Green", "Blue"].map((label, index) => row(jsx(DFL.SliderField, {
                label: `${title} · ${label}`,
                value: parseInt(color.slice(index * 2, index * 2 + 2), 16),
                min: 0, max: 255, step: 1, showValue: true,
                disabled: !st.sticks_led || cfg.mode === "off",
                onChange: (v) => {
                    const old = current.current[key] || "000000";
                    change({ [key]: old.slice(0, index * 2) + Math.round(v).toString(16).padStart(2, "0") + old.slice(index * 2 + 2) });
                },
            }))),
        ];
    };
    const animated = ["breath", "rgb-cycle"].includes(cfg.mode);
    const editable = !["google", "off"].includes(cfg.mode);
    const led = st.rgb_status || {};
    return jsxs(SP_JSX.Fragment, { children: [
        row(jsx(DFL.DropdownItem, {
            label: "Pocket EVO stick lighting",
            description: "Applies to both joystick rings",
            rgOptions: EVO_MODES, selectedOption: cfg.mode,
            disabled: !st.sticks_led,
            onChange: (o) => change(saved.current[o.data] || { ...cfg, mode: o.data }),
        })),
        row(jsx(DFL.ToggleField, {
            label: "Customize", checked: customize,
            description: "Save color and brightness separately for each effect",
            onChange: setCustomize,
        })),
        ...(customize && editable ? [row(jsx(DFL.SliderField, {
            label: "Brightness", value: cfg.brightness ?? 160,
            min: 0, max: 255, step: 5, showValue: true,
            disabled: !st.sticks_led || cfg.mode === "off",
            onChange: (v) => change({ brightness: Math.round(v) }),
        })),
        ...(["default", "static", "breath", "follow"].includes(cfg.mode) ? colorSliders("color", cfg.mode === "follow" ? "Active color" : "Color") : []),
        ...(cfg.mode === "follow" ? colorSliders("secondary_color", "Background color") : []),
        animated ? row(jsx(DFL.SliderField, {
            label: "Effect speed", value: cfg.speed, min: 0.25, max: 3, step: 0.25,
            showValue: true, valueSuffix: "×", disabled: !st.sticks_led,
            onChange: (v) => change({ speed: v }),
        })) : null] : []),
        cfg.mode === "google" ? note("Multi-color ring effect; color, brightness and speed are automatic") : null,
        note(!st.sticks_led ? "Pocket EVO LED serial port is unavailable"
            : led.error || (led.sleeping ? "Lights paused during sleep" : led.ready ? "LED controller connected" : "Waiting for LED controller")),
    ] });
}

function Content() {
    const [st, setSt] = useState(null);
    const [shortFps, setShortFps] = useState(shortFpsWanted());
    const refresh = useCallback(() => {
        getState().then(setSt).catch(() => {});
    }, []);
    useEffect(() => {
        refresh();
        const t = setInterval(refresh, 2000);
        return () => clearInterval(t);
    }, [refresh]);

    if (!st) {
        return jsx(DFL.PanelSection, { children: row("Loading…") });
    }
    const prof = PROFILES.find((p) => p.data === st.profile) || PROFILES[1];
    const fan = st.fan || { mode: "auto", fixed: 50, boost: false };
    const status = [
        st.temp_c != null ? `${st.temp_c} °C` : null,
        st.fan_rpm != null ? `fan ${st.fan_rpm} rpm (${Math.round((st.fan_pwm || 0) / 2.55)}%)` : null,
        st.gpu_mhz != null ? `GPU ${st.gpu_mhz} MHz` : null,
    ].filter(Boolean).join(" · ");

    return jsxs(SP_JSX.Fragment, { children: [
        jsxs(DFL.PanelSection, { title: "Performance", children: [
            row(jsx(DFL.DropdownItem, {
                label: "Profile",
                description: prof.desc,
                rgOptions: PROFILES.map((p) => ({ data: p.data, label: p.label })),
                selectedOption: st.profile,
                onChange: (o) => setProfile(o.data).then(refresh),
            })),
            note(st.daemon ? status : `${st.daemon_name || "konkrd"} is not running`),
        ] }),
        jsxs(DFL.PanelSection, { title: "Fan", children: [
            row(jsx(DFL.DropdownItem, {
                label: "Mode",
                description: fan.mode === "fixed"
                    ? "Fixed speed (switches back to automatic above 90 °C)"
                    : "Automatic, follows the profile's temperature curve",
                rgOptions: [{ data: "auto", label: "Automatic" }, { data: "fixed", label: "Fixed speed" }],
                selectedOption: fan.mode,
                onChange: (o) => setFan(o.data, fan.fixed, fan.boost).then(refresh),
            })),
            fan.mode === "fixed" ? row(jsx(DFL.SliderField, {
                label: "Speed",
                value: fan.fixed, min: 0, max: 100, step: 5, showValue: true, valueSuffix: "%",
                onChange: (v) => setFan("fixed", v, fan.boost),
            })) : row(jsx(DFL.ToggleField, {
                label: "Boost",
                description: "Use the Turbo fan curve with any profile",
                checked: !!fan.boost,
                onChange: (v) => setFan(fan.mode, fan.fixed, v).then(refresh),
            })),
            st.game && st.game.appid ? row(jsx(DFL.DropdownItem, {
                label: `For ${gameName(st.game.appid)}`,
                description: st.game.fan === "global"
                    ? "Uses the settings above. Pick a curve or speed to keep for this game"
                    : "Used whenever this game runs (above 90 °C a fixed speed still gives way)",
                rgOptions: GAME_FAN_OPTIONS,
                selectedOption: st.game.fan,
                onChange: (o) => setGameFan(st.game.appid, o.data).then(refresh),
            })) : null,
        ] }),
        st.bypass && st.bypass.supported ? jsxs(DFL.PanelSection, { title: "Battery", children: [
            row(jsx(DFL.ToggleField, {
                label: "Bypass charging",
                description: st.bypass.on
                    ? `Plugged in, the battery stays at ${st.bypass.level} % and the device runs from the charger`
                    : "Run from the charger and leave the battery alone, for long sessions plugged in (holds at 55 % or more)",
                checked: !!st.bypass.on,
                onChange: (v) => setBypass(v).then(refresh),
            })),
        ] }) : null,
        jsxs(DFL.PanelSection, { title: "Lighting", children: [
            st.evo_rgb ? jsx(EvoLighting, { st, refresh }) : jsxs(SP_JSX.Fragment, { children: [
            row(jsx(DFL.DropdownItem, {
                label: "Stick lighting",
                disabled: !st.sticks_led,
                description: st.sticks_led ? "" : (st.has_mcu_link ? "Needs the controller MCU link (below)" : "No stick lights found on this device"),
                rgOptions: RGB_PRESETS.map((p, i) => ({ data: i, label: p.label }))
                    .filter((o) => st.has_breath || RGB_PRESETS[o.data].mode !== "breath"),
                selectedOption: Math.max(0, RGB_PRESETS.findIndex((p) => p.mode === st.rgb.mode && p.color === st.rgb.color)),
                onChange: (o) => {
                    const p = RGB_PRESETS[o.data];
                    setRgb(p.mode, p.color, st.rgb.brightness || 160).then(refresh);
                },
            })),
            row(jsx(DFL.SliderField, {
                label: "Stick brightness",
                value: st.rgb.brightness || 160, min: 10, max: 255, step: 5,
                disabled: !st.sticks_led || st.rgb.mode !== "static",
                onChange: (v) => setRgb(st.rgb.mode, st.rgb.color, v),
            })),
            ] }),
            st.has_power_led ? row(jsx(DFL.ToggleField, {
                label: "Power LED",
                description: "Charging / full / low-battery colours and profile flashes",
                checked: st.power_led !== false,
                onChange: (v) => setPowerLed(v).then(refresh),
            })) : null,
        ] }),
        jsxs(DFL.PanelSection, { title: "Display", children: [
            row(jsx(DFL.ToggleField, {
                label: "Short frame limit list",
                description: shortFpsSteps(),
                checked: shortFps,
                onChange: (v) => { try { localStorage.setItem(SHORT_FPS_KEY, v ? "1" : "0"); } catch (e) {} setShortFps(v); applyShortFps(v); },
            })),
            st.has_motors ? row(jsx(DFL.ToggleField, {
                label: "Menu clicks",
                description: "A light buzz when moving through Steam's menus",
                checked: st.menu_clicks !== false,
                onChange: (v) => setMenuClicks(v).then(refresh),
            })) : null,
        ] }),
        st.fit_buttons ? jsxs(DFL.PanelSection, { title: "Buttons", children: [
            ...[["F13", "KONKR button"], ["F14", "Performance button"]].map(([key, label]) => row(jsx(DFL.DropdownItem, {
                label,
                description: (st.buttons || {})[key] === "game"
                    ? "A controller button: bind it per game in Steam's controller settings (shows as a trackpad click)"
                    : "",
                rgOptions: BUTTON_ACTIONS,
                selectedOption: (st.buttons || {})[key] || "none",
                onChange: (o) => setButton(key, o.data).then(refresh),
            }))),
            note("Home = Steam button · right front button = Quick Access · Power: tap to sleep, hold for the power menu"),
        ] }) : null,
        st.has_mcu_link ? jsxs(DFL.PanelSection, { title: "Hardware", children: [
            row(jsx(DFL.ToggleField, {
                label: "Controller MCU link",
                description: "Needed for the KONKR, Performance and Quick Access buttons and stick lighting",
                checked: st.mcu_enabled,
                onChange: (v) => setMcu(v).then(() => {
                    toaster.toast({ title: "Handheld Control", body: v ? "MCU link enabled" : "MCU link disabled" });
                    refresh();
                }),
            })),
        ] }) : null,
    ] });
}

// Toast whenever the profile or fan boost changes (KONKR button, konkrctl or
// this panel), like Android's on-screen mode switch. Registered at plugin
// load, so it works with Quick Access closed and over games.
const MODE_TOAST = {
    silent: { title: "🌙  Silent", body: "Quiet fan, GPU capped" },
    balanced: { title: "⚖️  Balanced", body: "Full clocks on demand" },
    turbo: { title: "⚡  Turbo", body: "Maximum performance, fan aggressive" },
};
function onMode(profile, boost, profileChanged) {
    const t = profileChanged
        ? MODE_TOAST[profile] || { title: profile, body: "" }
        : { title: boost ? "🌀  Fan boost on" : "🌀  Fan boost off", body: (MODE_TOAST[profile] || {}).title || "" };
    toaster.toast({ title: t.title, body: t.body, duration: 2000, playSound: false, critical: true });
}

var index = definePlugin(() => {
    api.addEventListener("konkr_mode", onMode);
    // Steam may not have its GamescopeService state yet at plugin load.
    let shortFpsTries = 0;
    const shortFpsTimer = setInterval(() => {
        if (!shortFpsWanted() || applyShortFps(true) || ++shortFpsTries > 30) clearInterval(shortFpsTimer);
    }, 2000);
    return {
        name: "Handheld Control",
        content: jsx(Content, {}),
        icon: jsx("div", { style: { fontWeight: 800 }, children: "H" }),
        alwaysRender: false,
        onDismount() {
            api.removeEventListener("konkr_mode", onMode);
            clearInterval(shortFpsTimer);
            if (shortFpsUnsub) { shortFpsUnsub(); shortFpsUnsub = null; }
        },
    };
});

export { index as default };
