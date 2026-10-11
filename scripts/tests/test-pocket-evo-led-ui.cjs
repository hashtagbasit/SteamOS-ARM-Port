// Exercise the actual component's selection, controls and queued API writes.
// Small hook harness; no browser or claim of Decky runtime rendering.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname,
    '../../external-and-mods/Decky/sm8650/konkr-control/dist/index.js'), 'utf8');
const hooks = [];
let cursor = 0, timer, timerId = 0;
const calls = [];
const jsx = (type, props) => ({ type, ...props });
const context = {
    jsx, jsxs: jsx, SP_JSX: { Fragment: 'fragment' },
    DFL: { DropdownItem: 'dropdown', SliderField: 'slider', ToggleField: 'toggle' },
    row: x => x, note: text => ({ type: 'note', text }),
    useRef(value) { const i = cursor++; return hooks[i] ??= { current: value }; },
    useState(value) {
        const i = cursor++;
        if (!(i in hooks)) hooks[i] = typeof value === 'function' ? value() : value;
        return [hooks[i], v => { hooks[i] = v; }];
    },
    useEffect() {},
    setTimeout(fn) { timer = fn; return ++timerId; },
    clearTimeout() { timer = null; },
    setRgb: async (...args) => { calls.push(args); },
    toaster: { toast: msg => { throw new Error(JSON.stringify(msg)); } },
};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf('const EVO_MODES ='), source.indexOf('function Content()')) +
    '\nglobalThis.renderLighting = EvoLighting;', context);
const st = {
    sticks_led: true,
    rgb: { mode: 'static', color: '123456', brightness: 64, speed: 1 },
    rgb_presets: {
        default: { mode: 'default', color: 'ffffff', brightness: 255, speed: 1 },
        google: { mode: 'google', color: 'ffffff', brightness: 255, speed: 1 },
        follow: { mode: 'follow', color: 'eb00ff', secondary_color: '0000ff', brightness: 255, speed: 1 },
    },
};
function render() {
    cursor = 0;
    return context.renderLighting({ st, refresh() {} }).children.filter(Boolean);
}
function field(label) { return render().find(x => x.label === label); }
(async () => {
    assert.deepEqual(Array.from(field('Pocket EVO stick lighting').rgOptions, x => x.label),
        ['Default', 'Breath – Single', 'Breath – RGB', 'Breath – Google', 'Static', 'Reactive', 'Off']);
    assert.equal(field('Brightness'), undefined);
    field('Customize').onChange(true);
    field('Brightness').onChange(80);
    // Switch before the debounce fires: keep the customized previous mode too.
    field('Pocket EVO stick lighting').onChange({ data: 'default' });
    assert.equal(field('Brightness').value, 255);
    await timer();
    assert.deepEqual(calls.map(x => [x[0], x[2]]), [['static', 80], ['default', 255]]);
    field('Pocket EVO stick lighting').onChange({ data: 'static' });
    assert.equal(field('Brightness').value, 80);
    await timer();
    field('Pocket EVO stick lighting').onChange({ data: 'google' });
    assert.equal(field('Brightness'), undefined);
    assert.equal(field('Effect speed'), undefined);
    assert.equal(render().filter(x => x.type === 'slider').length, 0);
    await timer();
    field('Pocket EVO stick lighting').onChange({ data: 'follow' });
    assert(field('Active color · Red'));
    assert(field('Background color · Blue'));
    await timer();
    console.log('PASS: Android effect list, Customize, per-mode values, queued saves and Google controls');
})().catch(e => { console.error(e); process.exitCode = 1; });
