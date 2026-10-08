// The bottom screen's home: a launcher, nothing else. Games are on the top
// screen and Steam's own Quick Access has the toggles, so this is the tools
// (dashboard, trackpad, keyboard, notes...), web apps and apps, as pages of
// tiles to swipe through. A running app has a lit dot; holding it closes it.
// What's playing sits in the corner while something plays.
//
// Holding the AYN button or swiping up from the bottom edge always lands here.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
    id: home
    property var running: []
    property var pinned: []
    property var web: []
    property var hub: []               // Emulator Hub apps (from /hub)
    property var recent: []            // not shown here any more (the top screen has them)
    readonly property var media: st.media || ({})
    readonly property var st: Ui.st
    readonly property var game: st.game || ({})
    // Apps worth having that aren't installed yet: one tap gets them, and
    // they pin themselves when done.
    readonly property var suggested: hub.filter(function (a) {
        return a.kind === "app" && !a.installed && a.available && ["vesktop", "signal", "artmoon", "chiaki"].indexOf(a.id) >= 0
    }).slice(0, 3)
    signal open(string page)

    readonly property var runningIds: running.map(function (a) { return a.id })
    readonly property var hidden: Ui.cfg.home_hidden || []

    // Every tile in order: tools, web apps, apps, apps to get, then Add.
    readonly property var items: {
        var out = []
        var tools = [
            { id: "page:dash", page: "dash", name: "Dashboard", icon: "speedometer", mask: true },
            { id: "page:pad", page: "pad", name: "Trackpad", icon: "input-touchpad-symbolic", mask: true },
            { id: "page:keys", page: "keys", name: "Keyboard", icon: "input-keyboard-symbolic", mask: true },
            { id: "page:notes", page: "notes", name: game.name ? "Notes" : "Game Notes", icon: "document-edit-symbolic", mask: true },
            { id: "page:hub", page: "hub", name: "Loadout", icon: "download-symbolic", mask: true },
            { id: "page:bricks", page: "bricks", name: "Bricks", icon: "games-config-board-symbolic", mask: true },
            // the only way in to the bottom screen's own settings (themes, idle
            // timeout, what shows where)
            { id: "page:settings", page: "settings", name: "Settings", icon: "configure-symbolic", mask: true }
        ]
        tools.forEach(function (t) { t.kind = "tool"; out.push(t) })
        web.forEach(function (w) {
            out.push({ id: w.id, name: w.id === "web:guide" ? "Guide" : w.name, icon: w.icon, kind: "web", web: true, mask: true })
        })
        pinned.forEach(function (p) { out.push({ id: p.id, name: p.name, icon: p.icon, kind: "app" }) })
        running.forEach(function (r) {
            if (!out.some(function (o) { return o.id === r.id }))
                out.push({ id: r.id, name: r.name, icon: r.icon, kind: "app" })
        })
        suggested.forEach(function (a) {
            out.push({ id: "get:" + a.id, name: a.title, icon: "applications-internet", image: a.icon || "", kind: "app", get: a })
        })
        out = out.filter(function (o) { return hidden.indexOf(o.id) < 0 })
        // the order set in Lower Deck; tiles it hasn't seen go after, as they were
        var order = Ui.cfg.home_order || []
        out = out.map(function (o, n) { return { o: o, n: n } }).sort(function (a, b) {
            var x = order.indexOf(a.o.id), y = order.indexOf(b.o.id)
            return (x < 0 ? 1000 + a.n : x) - (y < 0 ? 1000 + b.n : y)
        }).map(function (e) { return e.o })
        out.push({ id: "page:apps", page: "apps", name: "Add", icon: "list-add-symbolic", mask: true, kind: "add" })
        return out
    }
    readonly property int perPage: 12
    readonly property int pages: Math.max(1, Math.ceil(items.length / perPage))

    function activate(o) {
        if (o.page) home.open(o.page)
        else if (o.get) { if (!(o.get.job && o.get.job.state === "running")) Ui.post("/hub/install", { app: o.get.id, pin: true }) }
        else {
            var running = home.runningIds.indexOf(o.id) >= 0
            if (!running) Ui.launching = { name: o.name, icon: o.icon || "", image: o.image || "", web: !!o.web }
            Ui.post(running ? "/focus" : "/launch", { id: o.id })
        }
    }
    function hold(o) {
        if (home.runningIds.indexOf(o.id) >= 0) Ui.post("/close", { id: o.id })
        else if (o.id.indexOf("web:u-") === 0) home.open("newweb")
        else if (o.get) home.open("hub")
        else if (!o.page) home.open("apps")
    }

    // ----------------------------------------------------------- header --
    RowLayout {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 36 * Ui.s
        anchors.topMargin: 0
        // Takes room only while something plays.
        height: home.media.title ? 64 * Ui.s : 0
        spacing: 16 * Ui.s
        // Now playing, while something plays anywhere.
        Rectangle {
            visible: !!home.media.title
            Layout.preferredHeight: 64 * Ui.s
            Layout.preferredWidth: Math.min(640 * Ui.s, playRow.implicitWidth + 40 * Ui.s)
            radius: height / 2
            color: Ui.button
            border.color: Ui.cardEdge
            RowLayout {
                id: playRow
                anchors.fill: parent
                anchors.leftMargin: 10 * Ui.s
                anchors.rightMargin: 14 * Ui.s
                spacing: 12 * Ui.s
                Rectangle {
                    Layout.preferredWidth: 46 * Ui.s; Layout.preferredHeight: 46 * Ui.s
                    radius: width / 2; color: Ui.accent
                    Txt { anchors.centerIn: parent; text: home.media.status === "Playing" ? "⏸" : "▶"; font.pixelSize: 22 * Ui.s }
                    TapHandler { onTapped: Ui.post("/media", { action: "playpause" }) }
                }
                Txt {
                    Layout.fillWidth: true
                    text: (home.media.title || "") + (home.media.artist ? "  ·  " + home.media.artist : "")
                    elide: Text.ElideRight
                    font.pixelSize: 24 * Ui.s
                    font.weight: Font.DemiBold
                }
                Txt {
                    text: "⏭"; color: Ui.dim; font.pixelSize: 26 * Ui.s
                    TapHandler { onTapped: Ui.post("/media", { action: "next" }) }
                }
            }
        }
        Item { Layout.fillWidth: true }
        // (time and battery: Main.qml's corner, as on every page)
        Item { Layout.preferredWidth: 300 * Ui.s }
    }

    // --------------------------------------------------- game strip --
    // While a game runs: the things you reach for mid-game, one tap each.
    Rectangle {
        id: strip
        readonly property bool on: !!home.game.name && !Ui.st.desktop
        readonly property var fg: Ui.st.fg
        readonly property var art: home.game.art || ({})
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.leftMargin: 36 * Ui.s
        anchors.rightMargin: 36 * Ui.s
        anchors.topMargin: on ? 10 * Ui.s : 0
        height: on ? 96 * Ui.s : 0
        visible: on
        radius: height / 2
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "#1f3a5c" }
            GradientStop { position: 1; color: Ui.card }
        }
        border.color: Ui.cardEdge
        ArtFill { path: strip.art.hero || ""; radius: strip.radius; dim: 0.75 }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 34 * Ui.s
            anchors.rightMargin: 14 * Ui.s
            spacing: 12 * Ui.s
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Image {
                    id: stripLogo
                    anchors.verticalCenter: parent.verticalCenter
                    height: 70 * Ui.s
                    width: Math.min(parent.width, implicitWidth * height / Math.max(1, implicitHeight))
                    source: strip.art.logo ? "file://" + strip.art.logo : ""
                    sourceSize.height: 116
                    fillMode: Image.PreserveAspectFit
                    horizontalAlignment: Image.AlignLeft
                    visible: status === Image.Ready
                }
                Txt {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    visible: !stripLogo.visible
                    text: home.game.name || ""
                    elide: Text.ElideRight
                    font.pixelSize: 28 * Ui.s
                    font.weight: Font.Bold
                }
            }
            component Act: Btn {
                Layout.preferredHeight: 66 * Ui.s
                Layout.preferredWidth: 140 * Ui.s
                fontSize: 22
            }
            Act { label: "Notes"; onClicked: home.open("notes") }
            Act {
                visible: home.web.some(function (w) { return w.id === "web:guide" })
                label: "Guide"
                onClicked: Ui.post("/launch", { id: "web:guide" })
            }
            Act { label: "Capture"; onClicked: Ui.post("/steam/screenshot") }
            // Frame generation steps Off, 2x, 3x, 4x and back.
            Act {
                visible: !!strip.fg
                Layout.preferredWidth: 190 * Ui.s
                active: !!strip.fg && strip.fg.multiplier > 1
                label: strip.fg ? "Frame gen " + (strip.fg.multiplier > 1 ? strip.fg.multiplier + "×" : "off") : ""
                onClicked: Ui.post("/fg", { multiplier: strip.fg.multiplier >= 4 ? 1 : (strip.fg.multiplier < 2 ? 2 : strip.fg.multiplier + 1) })
            }
        }
    }

    // ------------------------------------------------------------ tiles --
    ListView {
        id: pager
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: strip.bottom
        anchors.topMargin: 10 * Ui.s
        anchors.bottom: dots.top
        anchors.bottomMargin: 18 * Ui.s
        orientation: ListView.Horizontal
        snapMode: ListView.SnapOneItem
        highlightRangeMode: ListView.StrictlyEnforceRange
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        model: home.pages
        delegate: Item {
            id: pageItem
            required property int index
            width: pager.width
            height: pager.height
            Grid {
                anchors.centerIn: parent
                scale: strip.on ? 0.9 : 1          // room for the game strip
                columns: 4
                columnSpacing: 34 * Ui.s
                rowSpacing: 16 * Ui.s
                Repeater {
                    model: home.items.slice(pageItem.index * home.perPage, (pageItem.index + 1) * home.perPage)
                    Tile {
                        required property var modelData
                        readonly property var job: modelData.get && modelData.get.job && modelData.get.job.state === "running" ? modelData.get.job : null
                        name: job ? Math.round(job.pct) + "%" : modelData.name
                        icon: modelData.icon || "application-x-executable"
                        image: modelData.image || ""
                        kind: modelData.kind
                        mask: !!modelData.mask || (modelData.icon || "").endsWith("-symbolic")
                        running: home.runningIds.indexOf(modelData.id) >= 0
                        download: !!modelData.get
                        progress: job ? job.pct : -1
                        onTapped: home.activate(modelData)
                        onHeld: home.hold(modelData)
                    }
                }
            }
        }
    }

    // A dot per page, when there's more than one.
    Row {
        id: dots
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 22 * Ui.s
        spacing: 14 * Ui.s
        height: 14 * Ui.s
        visible: home.pages > 1
        Repeater {
            model: home.pages
            Rectangle {
                required property int index
                width: index === pager.currentIndex ? 40 * Ui.s : 14 * Ui.s
                height: 14 * Ui.s
                radius: height / 2
                color: index === pager.currentIndex ? Ui.accent : Ui.line
                Behavior on width { NumberAnimation { duration: 160 } }
            }
        }
    }
}
