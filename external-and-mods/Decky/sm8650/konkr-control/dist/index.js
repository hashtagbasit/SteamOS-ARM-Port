const manifest = { name: "Handheld Control" };
const API_VERSION = 2;
const internalAPIConnection =
  window.__DECKY_SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED_deckyLoaderAPIInit;
if (!internalAPIConnection) {
  throw new Error(
    "[@decky/api]: Failed to connect to the loader as as the loader API was not initialized. This is likely a bug in Decky Loader.",
  );
}
let api;
try {
  api = internalAPIConnection.connect(API_VERSION, manifest.name);
} catch {
  api = internalAPIConnection.connect(1, manifest.name);
}
const callable = api.callable;
const toaster = api.toaster;
const routerHook = api.routerHook;
const definePlugin =
  (fn) =>
  (...args) =>
    fn(...args);

const DFL = window.DFL;
const SP_REACT = window.SP_REACT;
const SP_JSX = window.SP_JSX;
const { useEffect, useState, useCallback } = SP_REACT;
const jsx = SP_JSX.jsx;
const jsxs = SP_JSX.jsxs;

// Decky callable(): arguments are passed positionally to the Python method.
const getState = callable("get_state");
const getLights = callable("get_lights");
const getCpu = callable("get_cpu");
const setCpu = callable("set_cpu");
const setLights = callable("set_lights");
const setMcu = callable("set_mcu");
const setFan = callable("set_fan");
const setPowerLed = callable("set_power_led");
const setFlip = callable("set_flip");
const bootAndroid = callable("boot_android");
const setMenuClicks = callable("set_menu_clicks");
const setBypass = callable("set_bypass");
const setButton = callable("set_button");
const setGameFan = callable("set_game_fan");
function hexToHs(hex) {
  const n = parseInt((hex || "ff3c00").padEnd(6, "0").slice(0, 6), 16) || 0;
  const r = ((n >> 16) & 255) / 255,
    g = ((n >> 8) & 255) / 255,
    b = (n & 255) / 255;
  const mx = Math.max(r, g, b),
    d = mx - Math.min(r, g, b);
  let h = 0;
  if (d) {
    h =
      mx === r
        ? ((g - b) / d) % 6
        : mx === g
          ? (b - r) / d + 2
          : (r - g) / d + 4;
    h = (h * 60 + 360) % 360;
  }
  return { h: Math.round(h), s: Math.round((mx ? d / mx : 0) * 100) };
}
function hsToHex(h, s) {
  const sat = s / 100,
    k = (n) => (n + h / 60) % 6;
  const f = (n) =>
    Math.round(255 * (1 - sat * Math.max(0, Math.min(k(n), 4 - k(n), 1))));
  return [f(5), f(3), f(1)]
    .map((v) => v.toString(16).padStart(2, "0"))
    .join("");
}

const row = (child) => jsx(DFL.PanelSectionRow, { children: child });
const note = (text) =>
  row(
    jsx("div", { style: { fontSize: "12px", opacity: 0.75 }, children: text }),
  );
const settingsSection = (title, children) =>
  jsxs(DFL.DialogControlsSection, {
    children: [
      jsx(DFL.DialogControlsSectionHeader, { children: title }),
      ...children,
    ],
  });

function useDeviceState() {
  const [st, setSt] = useState(null);
  const refresh = useCallback(() => {
    getState()
      .then(setSt)
      .catch(() => {});
  }, []);
  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 2000);
    return () => clearInterval(t);
  }, [refresh]);
  return [st, refresh];
}

const EFFECT_LABELS = {
  static: "Solid",
  breath: "Breathe",
  chroma: "Chroma",
  rainbow: "Rainbow",
  battery: "Battery level",
  heat: "Temperature",
};
const HUE_GRADIENT =
  "linear-gradient(to right, #f00 0%, #ff0 17%, #0f0 33%, #0ff 50%, #00f 67%, #f0f 83%, #f00 100%)";
let lightsInfo = null;
let lightsTimer = null;
let lightsSeq = 0;
let lightsEdited = 0;

function LightsSection() {
  const [l, setL] = useState(lightsInfo);
  const [hs, setHs] = useState(() =>
    hexToHs(lightsInfo ? lightsInfo.color : "ff3c00"),
  );
  useEffect(() => {
    let live = true;
    const pull = () => {
      const seq = lightsSeq;
      getLights()
        .then((s) => {
          if (
            !live ||
            seq !== lightsSeq ||
            lightsTimer ||
            Date.now() - lightsEdited < 1500
          )
            return;
          lightsInfo = s;
          setL(s);
        })
        .catch(() => {});
    };
    pull();
    const t = setInterval(pull, 2000);
    return () => {
      live = false;
      clearInterval(t);
    };
  }, []);
  useEffect(() => {
    if (l && hsToHex(hs.h, hs.s) !== l.color) setHs(hexToHs(l.color));
  }, [l && l.color]);
  if (!l || !(l.present || l.needs_mcu)) return null;

  const update = (patch, delay) => {
    const next = { ...l, ...patch };
    setL(next);
    lightsEdited = Date.now();
    const seq = ++lightsSeq;
    clearTimeout(lightsTimer);
    lightsTimer = setTimeout(() => {
      lightsTimer = null;
      setLights(
        next.enabled,
        next.effect,
        next.color,
        next.brightness,
        next.speed,
      )
        .then((s) => {
          lightsInfo = s;
          if (seq === lightsSeq) setL(s);
        })
        .catch(() => {});
    }, delay);
  };
  const setColor = (h, s) => {
    setHs({ h, s });
    update({ color: hsToHex(h, s) }, 150);
  };
  const effects = l.effects.includes(l.effect)
    ? l.effects
    : [...l.effects, l.effect];
  const colored = l.effect === "static" || l.effect === "breath";
  const moving = ["breath", "chroma", "rainbow"].includes(l.effect);
  const off = !l.present || !l.enabled;
  return settingsSection("Joystick Lights", [
    jsx(DFL.ToggleField, {
      label: "Enable Joystick Lights",
      description: l.present
        ? ""
        : "Turn on Controller MCU link (Handheld, below) to use the stick lights",
      checked: l.present && l.enabled,
      disabled: !l.present,
      onChange: (v) => update({ enabled: v }, 0),
    }),
    jsx(DFL.DropdownItem, {
      label: "Effect",
      rgOptions: effects.map((e) => ({
        data: e,
        label: EFFECT_LABELS[e] || e,
      })),
      selectedOption: l.effect,
      disabled: off,
      onChange: (o) => update({ effect: o.data }, 0),
    }),
    colored
      ? jsx(DFL.SliderField, {
          label: jsxs("span", {
            style: {
              display: "inline-flex",
              alignItems: "center",
              gap: "12px",
            },
            children: [
              "Color",
              jsx("span", {
                style: {
                  width: "28px",
                  height: "16px",
                  borderRadius: "4px",
                  background: "#" + hsToHex(hs.h, hs.s),
                },
              }),
            ],
          }),
          description: jsx("div", {
            style: {
              height: "8px",
              borderRadius: "4px",
              background: HUE_GRADIENT,
              opacity: off ? 0.4 : 1,
            },
          }),
          value: hs.h,
          min: 0,
          max: 355,
          step: 5,
          disabled: off,
          onChange: (h) => setColor(h, hs.s),
        })
      : null,
    colored
      ? jsx(DFL.SliderField, {
          label: "Saturation",
          value: hs.s,
          min: 0,
          max: 100,
          step: 5,
          showValue: true,
          valueSuffix: " %",
          disabled: off,
          onChange: (s) => setColor(hs.h, s),
        })
      : null,
    jsx(DFL.SliderField, {
      label: "Brightness",
      value: l.brightness,
      min: 0,
      max: 100,
      step: 5,
      showValue: true,
      valueSuffix: " %",
      disabled: off,
      onChange: (v) => update({ brightness: v }, 150),
    }),
    jsx(DFL.SliderField, {
      label: "Speed",
      description: !l.has_speed
        ? "These lights run their effects at one fixed speed"
        : moving
          ? ""
          : "For Breathe, Chroma and Rainbow",
      value: l.speed,
      min: 0,
      max: 100,
      step: 5,
      showValue: true,
      valueSuffix: " %",
      disabled: off || !moving || !l.has_speed,
      onChange: (v) => update({ speed: v }, 150),
    }),
  ]);
}

function PowerLedSection({ st, refresh }) {
  if (!st || !st.has_power_led) return null;
  return settingsSection("Power LED", [
    jsx(DFL.DropdownItem, {
      label: "Power LED",
      description:
        st.power_led === false
          ? "Off"
          : st.power_led_mode === "profile"
            ? "Blue Silent, green Balanced, red Turbo; pulses red when the battery is low"
            : "Amber charging, green full, pulses red when low; flashes the profile colour on a change",
      rgOptions: [
        { data: "charge", label: "Charging status" },
        { data: "profile", label: "Performance profile" },
        { data: "off", label: "Off" },
      ],
      selectedOption:
        st.power_led === false ? "off" : st.power_led_mode || "charge",
      onChange: (o) => setPowerLed(o.data).then(refresh),
    }),
  ]);
}

const BUTTON_ACTIONS = [
  { data: "profile-next", label: "Next performance profile" },
  { data: "rgb-next", label: "Next stick lighting" },
  { data: "sticks-toggle", label: "Stick lights on/off" },
  { data: "fan-boost", label: "Fan boost" },
  { data: "game", label: "Game button (bind in Steam)" },
  { data: "none", label: "Nothing" },
];

function HandheldSection({ st, refresh }) {
  if (!st || !(st.fit_buttons || st.has_mcu_link || st.has_motors)) return null;
  return settingsSection("Handheld", [
    ...(st.fit_buttons
      ? [
          ["F13", "KONKR button"],
          ["F14", "Performance button"],
        ]
      : []
    ).map(([key, label]) =>
      jsx(DFL.DropdownItem, {
        label,
        description:
          (st.buttons || {})[key] === "game"
            ? "A controller button: bind it per game in Steam's controller settings (shows as a trackpad click)"
            : "",
        rgOptions: BUTTON_ACTIONS,
        selectedOption: (st.buttons || {})[key] || "none",
        onChange: (o) => setButton(key, o.data).then(refresh),
      }),
    ),
    st.has_mcu_link
      ? jsx(DFL.ToggleField, {
          label: "Controller MCU link",
          description:
            "Needed for the KONKR, Performance and Quick Access buttons and stick lighting",
          checked: st.mcu_enabled,
          onChange: (v) =>
            setMcu(v).then(() => {
              toaster.toast({
                title: "Controller MCU link",
                body: v ? "Enabled" : "Disabled",
              });
              refresh();
            }),
        })
      : null,
    st.has_motors
      ? jsx(DFL.ToggleField, {
          label: "Menu clicks",
          description: "A light buzz when moving through Steam's menus",
          checked: st.menu_clicks !== false,
          onChange: (v) => setMenuClicks(v).then(refresh),
        })
      : null,
    st.fit_buttons
      ? jsx(DFL.Field, {
          label: "Fixed buttons",
          description:
            "Home = Steam button · right front button = Quick Access · Power: tap to sleep, hold for the power menu",
          focusable: false,
        })
      : null,
  ]);
}

function CustomizationSections() {
  const [st, refresh] = useDeviceState();
  return jsxs(SP_JSX.Fragment, {
    children: [
      jsx(LightsSection, {}),
      jsx(PowerLedSection, { st, refresh }),
      jsx(HandheldSection, { st, refresh }),
    ],
  });
}

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
  try {
    return localStorage.getItem(SHORT_FPS_KEY) !== "0";
  } catch (e) {
    return true;
  }
}
function findQueryClient() {
  if (queryClient) return queryClient;
  try {
    // Decky's module search: Steam's loader doesn't expose its module cache.
    // By shape only: the GamescopeService entry is only filled once
    // something asks for it, and the subscription catches that.
    queryClient =
      DFL.findModuleExport(
        (e) =>
          e &&
          typeof e.getQueryData === "function" &&
          typeof e.getQueryCache === "function" &&
          typeof e.setQueryData === "function" &&
          typeof e.invalidateQueries === "function",
      ) || null;
  } catch (e) {
    console.log("Handheld Control: query cache", e);
  }
  return queryClient;
}
function trimFrameRates(d) {
  const adi = d && d.active_display_info;
  const fr = adi && adi.supported_frame_rates,
    rr = adi && adi.supported_refresh_rates;
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
  const adi =
    qc &&
    qc.getQueryData(GS_STATE) &&
    qc.getQueryData(GS_STATE).active_display_info;
  const rr =
    adi && Array.isArray(adi.supported_refresh_rates)
      ? [...adi.supported_refresh_rates]
      : [];
  if (rr.some((r) => r % 30 === 0) && !rr.includes(30)) rr.push(30);
  rr.sort((a, b) => a - b);
  return rr.length ? rr.join(" / ") : "30 / 60 / 90 / 120";
}
function applyShortFps(on) {
  if (shortFpsUnsub) {
    shortFpsUnsub();
    shortFpsUnsub = null;
  }
  const qc = findQueryClient();
  if (!qc) return false;
  if (!on) {
    qc.invalidateQueries({ queryKey: GS_STATE });
    return true;
  }
  const apply = () => {
    const t = trimFrameRates(qc.getQueryData(GS_STATE));
    if (t) qc.setQueryData(GS_STATE, t);
  };
  shortFpsUnsub = qc.getQueryCache().subscribe((ev) => {
    const key = ev && ev.query && ev.query.queryKey;
    if (
      ev &&
      ev.type === "updated" &&
      key &&
      key[0] === GS_STATE[0] &&
      key[1] === GS_STATE[1]
    )
      apply();
  });
  apply();
  return true;
}

function DisplaySections() {
  const [st, refresh] = useDeviceState();
  const [shortFps, setShortFps] = useState(shortFpsWanted());
  return settingsSection("Handheld", [
    jsx(DFL.ToggleField, {
      label: "Short frame limit list",
      description: `Quick Access > Performance offers only ${shortFpsSteps()} as frame limits`,
      checked: shortFps,
      onChange: (v) => {
        try {
          localStorage.setItem(SHORT_FPS_KEY, v ? "1" : "0");
        } catch (e) {}
        setShortFps(v);
        applyShortFps(v);
      },
    }),
    st && st.has_flip
      ? jsx(DFL.ToggleField, {
          label: "Flip screen",
          description:
            "Turn Game Mode the other way up, for controllers that plug into the short side. Applies the next time Game Mode starts (restart the tablet)",
          checked: !!st.flip,
          onChange: (v) => setFlip(v).then(refresh),
        })
      : null,
  ]);
}

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

const CPU_LIMITS = [
  { data: "stock", label: "Stock" },
  { data: "small", label: "Small underclock" },
  { data: "medium", label: "Medium underclock" },
  { data: "large", label: "Large underclock" },
  { data: "custom", label: "Custom" },
];
const ghz = (khz) => `${(khz / 1e6).toFixed(2)} GHz`;
let cpuTimer = null;

function CpuSection() {
  const [cpu, setCpuState] = useState(null);
  const pull = useCallback(() => {
    if (!cpuTimer)
      getCpu()
        .then(setCpuState)
        .catch(() => {});
  }, []);
  useEffect(() => {
    pull();
    const t = setInterval(pull, 2000);
    return () => clearInterval(t);
  }, [pull]);
  if (!cpu || !cpu.supported) return null;
  const send = (limit, custom, delay) => {
    clearTimeout(cpuTimer);
    cpuTimer = setTimeout(() => {
      setCpu(limit, custom)
        .then((c) => {
          cpuTimer = null;
          setCpuState(c);
        })
        .catch(() => {
          cpuTimer = null;
        });
    }, delay);
  };
  const capsLine = cpu.clusters
    .map((c) => `C${c.cpu} ${ghz(c.cap)}`)
    .join(" · ");
  const tdpLower = cpu.clusters.some((c) => c.now < c.cap);
  const choose = (limit) => {
    const custom =
      limit === "custom"
        ? Object.fromEntries(cpu.clusters.map((c) => [String(c.cpu), c.cap]))
        : undefined;
    setCpuState({ ...cpu, limit });
    send(limit, custom, 0);
  };
  const slide = (c, i) => {
    const clusters = cpu.clusters.map((x) =>
      x.cpu === c.cpu ? { ...x, cap: c.freqs[i] } : x,
    );
    setCpuState({ ...cpu, clusters });
    send(
      "custom",
      Object.fromEntries(clusters.map((x) => [String(x.cpu), x.cap])),
      150,
    );
  };
  return jsxs(DFL.PanelSection, {
    title: "CPU",
    children: [
      row(
        jsx(DFL.DropdownItem, {
          label: "CPU Limit",
          description: capsLine + (tdpLower ? " · TDP Limit lower" : ""),
          rgOptions: CPU_LIMITS,
          selectedOption: cpu.limit,
          onChange: (o) => choose(o.data),
        }),
      ),
      ...(cpu.limit === "custom"
        ? cpu.clusters.map((c) =>
            row(
              jsx(DFL.SliderField, {
                label: `C${c.cpu} (${c.cores} cores)`,
                description: `${ghz(c.cap)} of ${ghz(c.max)}`,
                value: Math.max(0, c.freqs.indexOf(c.cap)),
                min: 0,
                max: c.freqs.length - 1,
                step: 1,
                onChange: (i) => slide(c, i),
              }),
            ),
          )
        : []),
    ],
  });
}

function PerformanceSections() {
  const [st, refresh] = useDeviceState();
  if (!st) return null;
  const fan = st.fan || { mode: "auto", fixed: 50, boost: false };
  const status = [
    st.temp_c != null ? `${st.temp_c} °C` : null,
    st.fan_rpm != null
      ? `fan ${st.fan_rpm} rpm (${Math.round((st.fan_pwm || 0) / 2.55)}%)`
      : null,
    st.gpu_mhz != null ? `GPU ${st.gpu_mhz} MHz` : null,
  ]
    .filter(Boolean)
    .join(" · ");
  return jsxs(SP_JSX.Fragment, {
    children: [
      jsx(CpuSection, {}),
      jsxs(DFL.PanelSection, {
        title: "Fan",
        children: [
          note(
            st.daemon ? status : `${st.daemon_name || "konkrd"} is not running`,
          ),
          row(
            jsx(DFL.DropdownItem, {
              label: "Fan Mode",
              description:
                fan.mode === "fixed"
                  ? "Back to Auto above 90 °C"
                  : "Follows the profile's temperature curve",
              rgOptions: [
                { data: "auto", label: "Auto" },
                { data: "fixed", label: "Fixed" },
              ],
              selectedOption: fan.mode,
              onChange: (o) =>
                setFan(o.data, fan.fixed, fan.boost).then(refresh),
            }),
          ),
          fan.mode === "fixed"
            ? row(
                jsx(DFL.SliderField, {
                  label: "Fan Speed",
                  value: fan.fixed,
                  min: 0,
                  max: 100,
                  step: 5,
                  showValue: true,
                  valueSuffix: "%",
                  onChange: (v) => setFan("fixed", v, fan.boost),
                }),
              )
            : row(
                jsx(DFL.ToggleField, {
                  label: "Fan Boost",
                  description: "Use the Turbo fan curve with any profile",
                  checked: !!fan.boost,
                  onChange: (v) => setFan(fan.mode, fan.fixed, v).then(refresh),
                }),
              ),
          st.game && st.game.appid
            ? row(
                jsx(DFL.DropdownItem, {
                  label: `Fan for ${gameName(st.game.appid)}`,
                  description:
                    st.game.fan === "global"
                      ? "Uses the settings above. Pick a curve or speed to keep for this game"
                      : "Used whenever this game runs (above 90 °C a fixed speed still gives way)",
                  rgOptions: GAME_FAN_OPTIONS,
                  selectedOption: st.game.fan,
                  onChange: (o) =>
                    setGameFan(st.game.appid, o.data).then(refresh),
                }),
              )
            : null,
        ],
      }),
      st.bypass && st.bypass.supported
        ? jsxs(DFL.PanelSection, {
            title: "Battery",
            children: [
              row(
                jsx(DFL.ToggleField, {
                  label: "Bypass Charging",
                  description: st.bypass.on
                    ? `Plugged in, the battery stays at ${st.bypass.level} % and the device runs from the charger`
                    : "Run from the charger and leave the battery alone, for long sessions plugged in (holds at 55 % or more)",
                  checked: !!st.bypass.on,
                  onChange: (v) => setBypass(v).then(refresh),
                }),
              ),
            ],
          })
        : null,
    ],
  });
}

function QuickSettingsSections() {
  const [st] = useDeviceState();
  if (!st || !st.has_dualboot) return null;
  const label = st.dualboot_label || "Restart into Android";
  const confirm = () =>
    DFL.showModal(
      jsx(DFL.ConfirmModal, {
        strTitle: label,
        strDescription: st.dualboot_text,
        strOKButtonText: "Restart",
        onOK: () => bootAndroid(),
      }),
    );
  return jsx(DFL.PanelSection, {
    title: "Other System",
    children: [
      row(
        jsx(DFL.ButtonItem, {
          layout: "below",
          onClick: confirm,
          children: label,
        }),
      ),
    ],
  });
}

const wrappers = new Map();
const isWrapper = new WeakSet();
function wrapped(type, tag, make) {
  let byType = wrappers.get(tag);
  if (!byType) wrappers.set(tag, (byType = new WeakMap()));
  let w = byType.get(type);
  if (!w) {
    w = make(type);
    byType.set(type, w);
    isWrapper.add(w);
  }
  return w;
}

function rewrap(el, tag, make) {
  return SP_REACT.createElement(wrapped(el.type, tag, make), {
    ...el.props,
    key: el.key,
  });
}

const SETTINGS_SECTIONS = {
  "/settings/customization": { Sections: CustomizationSections, first: true },
  "/settings/display": { Sections: DisplaySections, first: false },
};

function withSettingsSections(Sections, first) {
  return (type) =>
    function SettingsPageWithHandheld(props) {
      const body = type(props);
      const extra = jsx(Sections, {}, "steamos-arm-handheld");
      if (!body || !body.props || body.props.children === undefined) {
        return jsxs(SP_JSX.Fragment, {
          children: first ? [extra, body] : [body, extra],
        });
      }
      const kids = SP_REACT.Children.toArray(body.props.children);
      return first
        ? SP_REACT.cloneElement(body, undefined, extra, ...kids)
        : SP_REACT.cloneElement(body, undefined, ...kids, extra);
    };
}

function findSettingsNav(tree) {
  return DFL.findInReactTree(
    tree,
    (x) =>
      x &&
      Array.isArray(x.pages) &&
      x.pages.some(
        (p) =>
          p &&
          typeof p === "object" &&
          typeof p.route === "string" &&
          p.route.startsWith("/settings/"),
      ),
  );
}

function addSettingsSections(nav) {
  if (!nav) return;
  let pages = null;
  nav.pages.forEach((page, i) => {
    const want = page && SETTINGS_SECTIONS[page.route];
    const el = want && page.content;
    if (!el || typeof el.type !== "function" || isWrapper.has(el.type)) return;
    pages = pages || [...nav.pages];
    pages[i] = {
      ...page,
      content: rewrap(
        el,
        page.route,
        withSettingsSections(want.Sections, want.first),
      ),
    };
  });
  if (pages) nav.pages = pages;
}

function withSettingsPatch(type) {
  return function SettingsWithHandheld(props) {
    let tree = type(props);
    try {
      let nav = findSettingsNav(tree);
      for (
        let i = 0;
        !nav &&
        i < 3 &&
        tree &&
        typeof tree.type === "function" &&
        !(tree.type.prototype && tree.type.prototype.isReactComponent);
        i++
      ) {
        tree = tree.type(tree.props);
        nav = findSettingsNav(tree);
      }
      addSettingsSections(nav);
    } catch (e) {
      console.log("Handheld Control: settings sections", e);
    }
    return tree;
  };
}

function patchSettingsRoute(props) {
  const el = props && props.children;
  if (el && typeof el.type === "function" && !isWrapper.has(el.type)) {
    props.children = rewrap(el, "settings", withSettingsPatch);
  }
  return props;
}

function qamSections() {
  const tab = DFL.QuickAccessTab || {};
  return {
    [tab.Perf]: PerformanceSections,
    [tab.Settings]: QuickSettingsSections,
  };
}

function withPanelSections(Sections) {
  return (type) =>
    function PanelWithHandheld(props) {
      return jsxs(SP_JSX.Fragment, {
        children: [SP_REACT.createElement(type, props), jsx(Sections, {})],
      });
    };
}

function patchQamTabs(tabs) {
  if (!Array.isArray(tabs)) return;
  const extra = qamSections();
  for (const tab of tabs) {
    const Sections = tab && extra[tab.key];
    const el = Sections && tab.panel;
    if (!el || !el.type || isWrapper.has(el.type)) continue;
    tab.panel = rewrap(el, `qam-${tab.key}`, withPanelSections(Sections));
  }
}

function hookQam() {
  const hook = window.DeckyPluginLoader && window.DeckyPluginLoader.tabsHook;
  if (
    !hook ||
    typeof hook.render !== "function" ||
    hook.render.handheldOriginal
  )
    return () => {};
  const original = hook.render;
  hook.render = function (tabs, ...rest) {
    try {
      patchQamTabs(tabs);
    } catch (e) {
      console.log("Handheld Control: quick access", e);
    }
    return original.call(this, tabs, ...rest);
  };
  hook.render.handheldOriginal = original;
  return () => {
    if (hook.render.handheldOriginal === original) hook.render = original;
  };
}

const HIDDEN_ONCE_KEY = "steamos-arm:handheld-control-hidden";

async function hideFromDeckyOnce() {
  try {
    if (localStorage.getItem(HIDDEN_ONCE_KEY)) return;
    const loader = window.DeckyPluginLoader;
    const svc = loader && loader.hiddenPluginsService;
    if (!svc) return;
    await svc.invalidate();
    const hidden = loader.deckyState.publicState().hiddenPlugins || [];
    if (!hidden.includes(manifest.name))
      await svc.update([...hidden, manifest.name]);
    localStorage.setItem(HIDDEN_ONCE_KEY, "1");
  } catch (e) {
    console.log("Handheld Control: hide", e);
  }
}

function Content() {
  return jsx(DFL.PanelSection, {
    children: [
      note("Handheld Control's settings are in Steam now:"),
      note("Quick Access > Performance: fan, bypass charging"),
      note("Quick Access > Quick Settings: restart into Android"),
      note("Settings > Customization: joystick lights, power LED, buttons"),
      note("Settings > Display: short frame limit list"),
    ],
  });
}

// Toast whenever the profile or fan boost changes (a device button, konkrctl
// or Steam's Performance tab), like Android's on-screen mode switch.
// Registered at plugin load, so it works with Quick Access closed and over
// games.
const MODE_TOAST = {
  silent: { title: "🌙  Silent", body: "Quiet fan, GPU capped" },
  balanced: { title: "⚖️  Balanced", body: "Full clocks on demand" },
  turbo: { title: "⚡  Turbo", body: "Maximum performance, fan aggressive" },
};
function onMode(profile, boost, profileChanged) {
  const t = profileChanged
    ? MODE_TOAST[profile] || { title: profile, body: "" }
    : {
        title: boost ? "🌀  Fan boost on" : "🌀  Fan boost off",
        body: (MODE_TOAST[profile] || {}).title || "",
      };
  toaster.toast({
    title: t.title,
    body: t.body,
    duration: 2000,
    playSound: false,
    critical: true,
  });
}

var index = definePlugin(() => {
  api.addEventListener("konkr_mode", onMode);
  // Steam may not have its GamescopeService state yet at plugin load.
  let shortFpsTries = 0;
  const shortFpsTimer = setInterval(() => {
    if (!shortFpsWanted() || applyShortFps(true) || ++shortFpsTries > 30)
      clearInterval(shortFpsTimer);
  }, 2000);
  getLights()
    .then((s) => {
      lightsInfo = s;
    })
    .catch(() => {});
  const settingsPatch = routerHook.addPatch("/settings", patchSettingsRoute);
  const unhookQam = hookQam();
  hideFromDeckyOnce();
  return {
    name: "Handheld Control",
    content: jsx(Content, {}),
    icon: jsx("div", { style: { fontWeight: 800 }, children: "H" }),
    alwaysRender: false,
    onDismount() {
      api.removeEventListener("konkr_mode", onMode);
      clearInterval(shortFpsTimer);
      routerHook.removePatch("/settings", settingsPatch);
      unhookQam();
      if (shortFpsUnsub) {
        shortFpsUnsub();
        shortFpsUnsub = null;
      }
    },
  };
});

export { index as default };
