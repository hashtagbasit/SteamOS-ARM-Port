from pathlib import Path
import os
import shlex
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
backend = (root / "external-and-mods/gamescope/src/Backends/DRMBackend.cpp").read_text()
script = (root / "external-and-mods/gamescope/src/Script/Script.cpp").read_text()
backend = backend[backend.index("\tvoid CDRMConnector::ParseEDID()"):]


def condition(source, prefix):
    matches = [line.strip()[5:-2] for line in source.splitlines()
               if line.strip().startswith("if ( " + prefix)]
    if len(matches) != 1:
        raise ValueError(f"Expected one panel condition starting with {prefix}")
    return matches[0]


start = backend.index("auto collectModeRefreshRates = [this]()")
end = backend.index("\n\t\t};", start) + len("\n\t\t};")
collector = backend[start:end]
start = backend.index("if ( !pEdid &&")
end = backend.index("\n\t\t\tif ( oKnownDisplay )", start)
guard = backend[start:end]
lookup = backend[backend.index("auto oKnownDisplay ="):start]
if 'm_Mutable.szName, pEdid ? "" : "ayn_odin2_portal" );' not in lookup:
    raise ValueError("EDID-less lookup must be limited to the Portal profile")

program = r"""
#include <algorithm>
#include <cassert>
#include <functional>
#include <memory>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

constexpr int GAMESCOPE_SCREEN_TYPE_INTERNAL = 0;
struct drmModeModeInfo { int hdisplay, vdisplay, vrefresh; };
struct Connector { int count_modes; drmModeModeInfo *modes; };
const drmModeModeInfo *find_mode(Connector *connector, int, int, int)
{
    return connector->count_modes ? connector->modes : nullptr;
}
namespace Algorithm {
template<typename T> bool Contains(const std::vector<T> &values, T value)
{
    return std::find(values.begin(), values.end(), value) != values.end();
}
}
struct {
    template<typename... Args> void infof(const char *, Args...) {}
} drm_log;

struct Panel {
    struct {
        std::vector<int> ValidDynamicRefreshRates = {123};
        std::function<void()> fnDynamicModeGenerator = [] {};
        const char *szName = "DSI-1";
    } m_Mutable;
    drmModeModeInfo modes[5] = {{1920, 1080, 120}, {1920, 1080, 60},
                               {1920, 1080, 120}, {1280, 720, 90}, {1920, 1080, 90}};
    std::unique_ptr<Connector> m_pConnector = std::make_unique<Connector>(Connector{5, modes});
    int screen = GAMESCOPE_SCREEN_TYPE_INTERNAL;
    bool reachedColorAndHDR = false;
    int GetScreenType() { return screen; }

    void parse(bool pEdid, std::optional<std::pair<std::string_view, int>> oKnownDisplay,
               bool profileModeGenerator = false)
    {
COLLECTOR
GUARD
        if (oKnownDisplay && profileModeGenerator)
            m_Mutable.fnDynamicModeGenerator = [] {};
        if (REFRESH)
            collectModeRefreshRates();
        reachedColorAndHDR = true;
    }
};

struct Key {
    std::string_view value;
    template<typename T> T as() const { return value; }
};
bool skipProfile(std::string_view psvProfile, std::string_view key)
{
    struct { Key first; } iter{{key}};
    return FILTER;
}
int main()
{
    using Match = std::optional<std::pair<std::string_view, int>>;
    Match portal = std::pair{"ayn_odin2_portal", 0};
    Match other = std::pair{"other_handheld", 0};
    const std::vector<int> expected = {60, 90, 120};
    for (Match match : {Match{}, other}) {
        Panel panel;
        panel.parse(false, match);
        assert(!panel.reachedColorAndHDR);
        assert(panel.m_Mutable.fnDynamicModeGenerator);
        assert(panel.m_Mutable.ValidDynamicRefreshRates == expected);
    }
    Panel external;
    external.screen = 1;
    external.parse(false, {});
    assert(!external.reachedColorAndHDR && external.m_Mutable.ValidDynamicRefreshRates.empty());
    assert(external.m_Mutable.fnDynamicModeGenerator);
    Panel empty;
    empty.m_pConnector->count_modes = 0;
    empty.parse(false, {});
    assert(!empty.reachedColorAndHDR && empty.m_Mutable.ValidDynamicRefreshRates.empty());
    for (bool edid : {false, true}) {
        Panel panel;
        panel.parse(edid, portal);
        assert(panel.reachedColorAndHDR && panel.m_Mutable.ValidDynamicRefreshRates == expected);
    }
    Panel unknown;
    unknown.parse(true, {});
    assert(unknown.reachedColorAndHDR && unknown.m_Mutable.ValidDynamicRefreshRates == expected);
    for (Match match : {portal, other}) {
        Panel generated;
        generated.parse(true, match, true);
        assert(generated.reachedColorAndHDR && generated.m_Mutable.fnDynamicModeGenerator);
        assert(generated.m_Mutable.ValidDynamicRefreshRates.empty());
    }
    Panel known;
    known.parse(true, other);
    assert(known.reachedColorAndHDR && known.m_Mutable.ValidDynamicRefreshRates.empty());
    assert(!skipProfile("", "other_handheld"));
    assert(!skipProfile("", "ayn_odin2_portal"));
    assert(!skipProfile("ayn_odin2_portal", "ayn_odin2_portal"));
    assert(skipProfile("ayn_odin2_portal", "other_handheld"));
}
"""
program = (program.replace("COLLECTOR", collector).replace("GUARD", guard)
           .replace("REFRESH", condition(backend, "!oKnownDisplay ||"))
           .replace("FILTER", condition(script, "!psvProfile.empty()")))
with tempfile.TemporaryDirectory(prefix="panel-scope-") as directory:
    path = Path(directory)
    (path / "test.cpp").write_text(program)
    subprocess.run([*shlex.split(os.environ.get("CXX", "c++")), "-std=c++20",
                    "-Wall", "-Wextra", "-Werror", str(path / "test.cpp"),
                    "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
print("Portal-only EDID and legacy panel refresh checks passed")
