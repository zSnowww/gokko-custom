import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import shell.services
import shell.services as Ryoku
import "I18n.js" as I18n
import "Fonts.js" as Fonts
import "SpotMath.js" as SpotMath
import "." as MacParts

Scope {
    id: root

    property var hostScreen: null
    property bool openRequested: false
    property bool perfNoFocus: false
    property string launcherQuery: ""
    signal dismissed()
    signal openModeRequested()

    // Persisted / shared appearance & preferences
    property bool darkMode: true
    property string appearanceMode: "dark"
    property color accent: "#0A84FF"
    property string fontFamily: "Open Runde"
    property string barStyle: "liquid"
    property real glassOpacity: 0.42
    property real glassRim: 0.45
    property real glassGrain: 0.015
    property real glassLiquid: 1.0
    property bool clipHistory: true
    property bool clipAutoPaste: true
    property bool use24h: true
    property string wallpaperPath: ""
    property string terminal: "kitty"
    property var appUsage: ({})
    property var emojiRecent: []

    readonly property bool panelDarkMode: darkMode
    readonly property bool liquidActive: barStyle === "liquid"
    readonly property url glassShaderUrl: Qt.resolvedUrl("liquidglass.frag.qsb")
    readonly property string boldFontFamily: "Open Runde Semibold"
    function fontForWeight(weight, regularFamily) {
        return (Number(weight) >= Font.DemiBold && regularFamily === "Open Runde") ? boldFontFamily : regularFamily;
    }

    // Internal Spotlight state
    property string spMode: "home"      // home | files | actions | apps | clip | emoji
    property string spQuery: ""
    property string spPaintQuery: ""
    property string spHoverLabel: ""
    property int spSel: 0
    property bool spHover: false
    property bool spCalm: false
    property string armed: ""
    property string emojiFont: "Noto Color Emoji"
    property bool spotOpen: false
    property double openedAtMs: 0

    // Background / search indexes
    property var devProjects: []
    property string fileQuery: ""
    property string fileSearchFor: ""
    property bool fileSearchPending: false
    property var fileHits: []
    property string clipState: "unknown"
    property var clipEntries: []
    property bool clipLoading: false

    readonly property string configDir: Quickshell.env("HOME") + "/.config/macbar"
    readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/macbar"

    QtObject {
        id: panelPal
        readonly property bool dark: root.panelDarkMode
        readonly property string fam: root.fontFamily
        readonly property color fg: dark ? Qt.color("#FFFFFF") : Qt.color("#1D1D1F")
        readonly property color fg2: dark ? Qt.rgba(1, 1, 1, 0.62) : Qt.rgba(0, 0, 0, 0.55)
        readonly property color fg3: dark ? Qt.rgba(1, 1, 1, 0.34) : Qt.rgba(0, 0, 0, 0.34)
        readonly property color hover: dark ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(0, 0, 0, 0.09)
        readonly property color sep: dark ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(0, 0, 0, 0.12)
        readonly property color borderTint: dark ? Qt.rgba(0.84, 0.89, 0.96, 1) : Qt.rgba(0.32, 0.36, 0.44, 1)
    }

    // Wallpaper path resolved immediately from Ryoku.Session or settings.json without spawning subshells
    readonly property string resolvedWallpaper: {
        var rw = String(Ryoku.Session.wallpaper || "");
        var p = rw !== "" ? rw : wallpaperPath;
        if (p.indexOf("~/") === 0) p = Quickshell.env("HOME") + p.substring(1);
        return p;
    }
    readonly property url wallpaperUrl: {
        var p = resolvedWallpaper;
        if (p === "") return "";
        if (p.indexOf("file://") === 0) return p;
        if (p.charAt(0) !== "/") return "";
        return "file://" + encodeURI(p).replace(/#/g, "%23").replace(/\?/g, "%3F");
    }

    FileView {
        id: settingsStore
        path: root.configDir + "/settings.json"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                var o = JSON.parse(text());
                var keys = ["darkMode", "appearanceMode", "accent", "fontFamily", "barStyle", "glassOpacity",
                            "glassRim", "glassGrain", "glassLiquid", "clipHistory", "clipAutoPaste",
                            "use24h", "wallpaperPath", "terminal", "appUsage", "emojiRecent"];
                for (var i = 0; i < keys.length; i++) {
                    var k = keys[i];
                    if (o[k] !== undefined) try { root[k] = o[k]; } catch (e) {}
                }
            } catch (err) {}
        }
    }

    FileView {
        id: spotStateStore
        path: root.cacheDir + "/spot-state.json"
        printErrors: false
        onLoaded: {
            try {
                var o = JSON.parse(text());
                if (o.appUsage && typeof o.appUsage === "object") {
                    var merged = {};
                    for (var k in root.appUsage) merged[k] = root.appUsage[k];
                    for (var j in o.appUsage) merged[j] = Math.max(merged[j] || 0, o.appUsage[j] || 0);
                    root.appUsage = merged;
                }
                if (Array.isArray(o.emojiRecent) && o.emojiRecent.length > 0) root.emojiRecent = o.emojiRecent;
            } catch (err) {}
        }
    }
    function saveSpotState() {
        spotStateStore.setText(JSON.stringify({ appUsage: root.appUsage, emojiRecent: root.emojiRecent }));
    }

    function sh(cmd) { Quickshell.execDetached(["sh", "-c", cmd]); }
    function openInFirefox(url) {
        var u = String(url || "").trim();
        if (u === "") return;
        Quickshell.execDetached(["sh", "-c", 'if command -v firefox >/dev/null 2>&1; then nohup firefox "$1" >/dev/null 2>&1 & else nohup xdg-open "$1" >/dev/null 2>&1 & fi', "sh", u]);
    }
    function openFolderInTerminal(dir) {
        var d = String(dir || "").trim();
        if (d === "") return;
        Quickshell.execDetached(["sh", "-c", 'cd "$1" && exec ' + root.terminal, "sh", d]);
    }

    // Apps catalog (uses Quickshell's already-loaded DesktopEntries in memory)
    readonly property var appList: {
        var vals = DesktopEntries.applications.values, out = [];
        for (var i = 0; i < vals.length; i++) {
            var e = vals[i];
            if (!e || e.noDisplay) continue;
            out.push(e);
        }
        out.sort(function (a, b) { return a.name.localeCompare(b.name); });
        return out;
    }
    function iconSrc(name) {
        var fb = Quickshell.iconPath("application-x-executable", true);
        if (!name) return fb;
        if (name.indexOf("/") === 0) return "file://" + name;
        var p = Quickshell.iconPath(name, true);
        return p !== "" ? p : fb;
    }
    function lookupApp(id) {
        if (!id) return null;
        var e = DesktopEntries.byId(id);
        if (!e && DesktopEntries.heuristicLookup) e = DesktopEntries.heuristicLookup(id);
        return e;
    }
    function searchApps(q) {
        q = (q || "").trim().toLowerCase();
        if (q === "") return [];
        var list = appList, hits = [];
        for (var i = 0; i < list.length; i++) {
            var e = list[i], n = e.name.toLowerCase(), sc = 0;
            if (n === q) sc = 100;
            else if (n.indexOf(q) === 0) sc = 80;
            else if (n.indexOf(" " + q) >= 0) sc = 60;
            else if (n.indexOf(q) >= 0) sc = 40;
            else if ((e.genericName || "").toLowerCase().indexOf(q) >= 0) sc = 25;
            else if ((e.comment || "").toLowerCase().indexOf(q) >= 0) sc = 10;
            else {
                var kw = e.keywords || [];
                for (var k = 0; k < kw.length; k++) if (String(kw[k]).toLowerCase().indexOf(q) >= 0) { sc = 15; break; }
            }
            if (sc > 0) hits.push({ e: e, s: sc + Math.min(appUsage[e.id] || 0, 20) });
        }
        hits.sort(function (a, b) { return b.s - a.s; });
        return hits.map(function (h) { return h.e; });
    }
    readonly property var appSections: {
        var list = appList, usage = appUsage, i, j;
        var used = list.filter(function (e) { return (usage[e.id] || 0) > 0; });
        used.sort(function (a, b) { return (usage[b.id] || 0) - (usage[a.id] || 0); });
        var sug = used.slice(0, 10);
        for (i = 0; i < list.length && sug.length < 5; i++) {
            var dup = false;
            for (j = 0; j < sug.length; j++) if (sug[j].id === list[i].id) { dup = true; break; }
            if (!dup) sug.push(list[i]);
        }
        var cats = [
            ["Game", "Games"], ["Office", "Productivity & Finance"], ["Finance", "Productivity & Finance"],
            ["Network", "Internet & Social"], ["WebBrowser", "Internet & Social"], ["Development", "Developer Tools"],
            ["Graphics", "Graphics & Design"], ["AudioVideo", "Music & Video"], ["Audio", "Music & Video"],
            ["Video", "Music & Video"], ["Education", "Education & Science"], ["Science", "Education & Science"],
            ["Settings", "System"], ["System", "System"], ["Utility", "Utilities"]
        ];
        var order = ["Games", "Productivity & Finance", "Internet & Social", "Developer Tools",
                     "Graphics & Design", "Music & Video", "Education & Science", "Utilities", "System"];
        var map = {};
        for (i = 0; i < list.length; i++) {
            var cs = list[i].categories || [], cat = "Utilities";
            for (var ci = 0; ci < cats.length && cat === "Utilities"; ci++)
                for (var cj = 0; cj < cs.length; cj++) if (cs[cj] === cats[ci][0]) { cat = cats[ci][1]; break; }
            if (!map[cat]) map[cat] = [];
            map[cat].push(list[i]);
        }
        var secs = [{ name: "Suggestions", apps: sug }];
        for (i = 0; i < order.length; i++) if (map[order[i]]) secs.push({ name: order[i], apps: map[order[i]] });
        return secs;
    }
    function appSearchSection(q) {
        var r = searchApps(q);
        if (r.length > 48) r = r.slice(0, 48);
        return r.length > 0 ? [{ name: "Top Hits", apps: r }] : [];
    }
    function launchApp(e) {
        var u = {};
        for (var k in appUsage) u[k] = appUsage[k];
        u[e.id] = (u[e.id] || 0) + 1;
        appUsage = u;
        saveSpotState();
        e.execute();
    }
    function launchAndClose(e) {
        closeSpotlight();
        launchApp(e);
    }

    // ~/dev + Home file search (runs asynchronously without blocking open)
    Process {
        id: devScanProc
        running: true
        command: ["sh", "-c", "dev=\"$HOME/dev\"; [ -d \"$dev\" ] || exit 0; ls -1At \"$dev\" 2>/dev/null | grep -v '^\\.' | head -n 60 | while IFS= read -r n; do p=\"$dev/$n\"; [ -d \"$p\" ] && printf 'D|%s|%s\\n' \"$n\" \"$p\" || printf 'F|%s|%s\\n' \"$n\" \"$p\"; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n"), list = [];
                for (var i = 0; i < lines.length; i++) {
                    var parts = lines[i].split("|");
                    if (parts.length < 3) continue;
                    list.push({ isDir: parts[0] === "D", name: parts[1], path: parts.slice(2).join("|") });
                }
                root.devProjects = list;
            }
        }
    }
    Process {
        id: fileSearchProc
        command: ["sh", "-c", [
            "q=\"$1\"; [ -n \"$q\" ] || exit 0;",
            "{ [ -d \"$HOME/dev\" ] && find \"$HOME/dev\" -maxdepth 4 -iname \"*$q*\" \\( -name '.git' -o -name 'node_modules' -o -name 'target' -o -name 'dist' -o -name '.next' \\) -prune -o -iname \"*$q*\" -print 2>/dev/null;",
            "  find \"$HOME\" -maxdepth 4 \\( -path '*/.cache*' -o -path '*/.local/share/Trash*' -o -path '*/.git*' -o -path '*/node_modules*' -o -path \"$HOME/dev*\" \\) -prune -o -iname \"*$q*\" -print 2>/dev/null; } |",
            "awk '!seen[$0]++' | head -n 12 | while IFS= read -r p; do [ -d \"$p\" ] && printf 'D|%s\\n' \"$p\" || printf 'F|%s\\n' \"$p\"; done"
        ].join(" "), "sh", root.fileQuery]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.trim().split("\n"), a = [];
                for (var i = 0; i < lines.length; i++) {
                    if (lines[i] === "") continue;
                    var d = lines[i].indexOf("D|") === 0;
                    a.push({ path: (d || lines[i].indexOf("F|") === 0) ? lines[i].substring(2) : lines[i], isDir: d });
                }
                if (root.fileSearchFor === root.fileQuery) { root.fileHits = a; root.fileSearchPending = false; }
                else fileDebounce.restart();
            }
        }
        onExited: if (root.fileSearchFor !== root.fileQuery) fileDebounce.restart()
    }
    Timer {
        id: fileDebounce; interval: 220
        onTriggered: if (root.fileQuery.length > 0 && !fileSearchProc.running) {
            root.fileSearchFor = root.fileQuery; root.fileSearchPending = true; fileSearchProc.running = true;
        }
    }
    function updateFileSearch(q) {
        q = (q || "").trim();
        if (q === fileQuery) return;
        fileQuery = q;
        if (q === "") { fileHits = []; fileSearchPending = false; fileDebounce.stop(); return; }
        fileSearchPending = true;
        fileDebounce.restart();
    }

    // Clipboard history (only queried when switching to Clipboard tab)
    function clipRefresh() {
        if (clipLoading) return;
        clipLoading = true;
        clipListProc.running = true;
    }
    Process {
        id: clipListProc
        command: ["sh", "-c", [
            "if ! command -v cliphist >/dev/null 2>&1; then echo '@@MISSING@@'; exit 0; fi",
            "d=\"$HOME/.cache/macbar\"; mkdir -p \"$d/clip\"; t=\"$d/clip-times\"; touch \"$t\"",
            "l=$(mktemp); cliphist list 2>/dev/null | head -n 150 > \"$l\"",
            "awk -F'\\t' -v now=\"$(date +%s)\" 'FILENAME==ARGV[1]{s[$1]=1;next} !($1 in s){print $1\"\\t\"now}' \"$t\" \"$l\" >> \"$t\"",
            "awk -F'\\t' '$2 ~ /^\\[\\[ binary data/ {print $1}' \"$l\" | head -n 20 | while read -r id; do [ -s \"$d/clip/$id.img\" ] || cliphist decode \"$id\" > \"$d/clip/$id.img\" 2>/dev/null; done",
            "cat \"$l\"; echo '@@TIMES@@'; cat \"$t\"; rm -f \"$l\""
        ].join("\n")]
        stdout: StdioCollector {
            onStreamFinished: {
                root.clipLoading = false;
                if (text.indexOf("@@MISSING@@") === 0) { root.clipState = "missing"; root.clipEntries = []; return; }
                root.clipState = "ok";
                var parts = text.split("@@TIMES@@\n");
                var lines = parts[0].split("\n"), tl = (parts[1] || "").split("\n"), times = {}, res = [], i;
                for (i = 0; i < tl.length; i++) { var p = tl[i].split("\t"); if (p.length >= 2) times[p[0]] = parseInt(p[1]); }
                for (i = 0; i < lines.length; i++) {
                    var tab = lines[i].indexOf("\t"); if (tab < 1) continue;
                    var id = lines[i].substring(0, tab), txt = lines[i].substring(tab + 1);
                    var en = { id: id, text: txt, kind: "text", title: txt, label: I18n.tr("Text"), thumb: "", color: "" };
                    var m = /^\[\[ binary data ([\d.]+ \w+) (\w+) (\d+x\d+) \]\]$/.exec(txt);
                    if (m) { en.kind = "image"; en.title = "Image " + m[3].replace("x", "\u00D7"); en.label = "Image \u2022 " + m[2].toUpperCase(); en.thumb = "file://" + root.cacheDir + "/clip/" + id + ".img"; }
                    else if (/^(https?|ftp):\/\/\S+$/i.test(txt) || /^www\.\S+\.\S+$/i.test(txt)) { en.kind = "url"; en.label = "URL"; }
                    else if (/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(txt)) { en.kind = "color"; en.color = txt; en.label = "Color"; }
                    en.sub = en.label;
                    res.push(en);
                }
                root.clipEntries = res;
            }
        }
    }
    function clipFiltered(q) {
        q = (q || "").trim().toLowerCase();
        var src = clipEntries, out = [];
        for (var i = 0; i < src.length && out.length < 100; i++) {
            var en = src[i];
            if (q !== "" && en.text.toLowerCase().indexOf(q) < 0) continue;
            var it = {}; for (var k in en) it[k] = en[k];
            it.run = (function (entry) { return function () { root.clipPick(entry, undefined); }; })(en);
            out.push(it);
        }
        return out;
    }
    function clipPick(en, paste) {
        var id = parseInt(en.id); if (isNaN(id)) return;
        sh("cliphist decode " + id + " | wl-copy");
        if (paste === undefined ? clipAutoPaste : paste) sh("sleep 0.2 && if command -v wtype >/dev/null 2>&1; then wtype -M ctrl -k v -m ctrl; fi");
    }
    function pickEmoji(en) {
        if (!en) return;
        var r = [en[0]];
        for (var i = 0; i < emojiRecent.length && r.length < 24; i++) if (emojiRecent[i] !== en[0]) r.push(emojiRecent[i]);
        emojiRecent = r;
        saveSpotState();
        closeSpotlight();
        Quickshell.execDetached(["sh", "-c", "printf %s \"$1\" | wl-copy", "sh", en[0]]);
        if (clipAutoPaste) sh("sleep 0.2 && if command -v wtype >/dev/null 2>&1; then wtype -M ctrl -k v -m ctrl; fi");
    }

    // Actions & Search Results Builders
    function actionItems(q) {
        var all = [
            { title: root.darkMode ? I18n.tr("Switch to Light Mode") : I18n.tr("Switch to Dark Mode"), kw: "theme appearance dark light mode", sub: I18n.tr("Appearance"), glyph: "contrast", run: function () { root.darkMode = !root.darkMode; Quickshell.execDetached(["qs", "-c", "shell", "ipc", "call", "macshell-spotlight", "setDark", root.darkMode ? "true" : "false"]); } },
            { title: I18n.tr("Toggle Night Light"), kw: "night shift warm screen", sub: I18n.tr("Display"), glyph: "nightshift", run: function () { Nightlight.setEnabled(!Nightlight.on, Nightlight.temperature); } },
            { title: I18n.tr("Toggle Keep Awake"), kw: "caffeine sleep inhibit awake", sub: I18n.tr("Power"), glyph: "coffee", run: function () { Flags.keepAwake = !Flags.keepAwake; } },
            { title: I18n.tr("Toggle Wi-Fi"), kw: "network wireless wifi", sub: I18n.tr("Network"), glyph: "wifi", run: function () { root.sh("nmcli radio wifi \"$([ \\\"$(nmcli radio wifi)\\\" = enabled ] && echo off || echo on)\""); } },
            { title: I18n.tr("Toggle Bluetooth"), kw: "bluetooth devices", sub: I18n.tr("Bluetooth"), glyph: "bluetooth", run: function () { root.sh("bluetoothctl show | grep -q 'Powered: yes' && bluetoothctl power off || bluetoothctl power on"); } },
            { title: I18n.tr("Toggle Mute"), kw: "sound audio volume mute", sub: I18n.tr("Sound"), glyph: "speaker", run: function () { root.sh("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"); } },
            { title: I18n.tr("Energy Mode: Low Power"), kw: "battery power saver profile", sub: I18n.tr("Battery"), glyph: "bolt", run: function () { Quickshell.execDetached(["powerprofilesctl", "set", "power-saver"]); } },
            { title: I18n.tr("Energy Mode: Automatic"), kw: "battery balanced profile", sub: I18n.tr("Battery"), glyph: "bolt", run: function () { Quickshell.execDetached(["powerprofilesctl", "set", "balanced"]); } },
            { title: I18n.tr("Energy Mode: High Power"), kw: "battery performance profile", sub: I18n.tr("Battery"), glyph: "bolt", run: function () { Quickshell.execDetached(["powerprofilesctl", "set", "performance"]); } },
            { title: I18n.tr("Clipboard History\u2026"), kw: "copy paste cliphist clipboard", sub: I18n.tr("Spotlight"), glyph: "clipboard", stayOpen: true, run: function () { root.setMode("clip"); } },
            { title: I18n.tr("Emoji & Symbols\u2026"), kw: "emoji symbols picker", sub: I18n.tr("Spotlight"), glyph: "smile", stayOpen: true, run: function () { root.setMode("emoji"); } },
            { title: I18n.tr("Search Files in ~/dev\u2026"), kw: "files projects dev folders", sub: I18n.tr("Spotlight"), glyph: "folder", stayOpen: true, run: function () { root.setMode("files"); } },
            { title: I18n.tr("Screenshot Selection\u2026"), kw: "capture screen area grim", sub: I18n.tr("Screenshot"), glyph: "photo", run: function () { Quickshell.execDetached(["qs", "-c", "shell", "ipc", "call", "macshell-screenshot", "region"]); } },
            { title: I18n.tr("Screenshot Screen"), kw: "capture screen full", sub: I18n.tr("Screenshot"), glyph: "photo", run: function () { Quickshell.execDetached(["qs", "-c", "shell", "ipc", "call", "macshell-screenshot", "screen"]); } },
            { title: I18n.tr("Pick Color"), kw: "color dropper hex hyprpicker", sub: I18n.tr("Utilities"), glyph: "camera", run: function () { root.sh("c=$(hyprpicker -a) && [ -n \"$c\" ] && notify-send -a macbar 'Color copied' \"$c\""); } },
            { title: I18n.tr("Open Terminal"), kw: "shell bash kitty console", sub: I18n.tr("Utilities"), glyph: "layers", run: function () { root.sh(root.terminal); } },
            { title: I18n.tr("System Settings\u2026"), kw: "preferences settings config", sub: I18n.tr("Settings"), glyph: "gear", run: function () { Quickshell.execDetached(["qs", "-c", "shell", "ipc", "call", "macshell-spotlight", "openPrefs", "menubar"]); } },
            { title: I18n.tr("Battery Settings\u2026"), kw: "battery power settings", sub: I18n.tr("Settings"), glyph: "gear", run: function () { Quickshell.execDetached(["qs", "-c", "shell", "ipc", "call", "macshell-spotlight", "openPrefs", "battery"]); } },
            { title: I18n.tr("Appearance Settings\u2026"), kw: "theme glass wallpaper settings", sub: I18n.tr("Settings"), glyph: "gear", run: function () { Quickshell.execDetached(["qs", "-c", "shell", "ipc", "call", "macshell-spotlight", "openPrefs", "appearance"]); } },
            { title: I18n.tr("Empty Trash"), kw: "trash delete clean bin", sub: I18n.tr("Finder"), glyph: "folder", confirm: true, run: function () { root.sh("rm -rf \"$HOME/.local/share/Trash/files/\"* \"$HOME/.local/share/Trash/info/\"* 2>/dev/null"); } },
            { title: I18n.tr("Lock Screen"), kw: "lock screen security", sub: I18n.tr("System"), glyph: "lock", run: function () { SessionActions.run("lock"); } },
            { title: I18n.tr("Sleep"), kw: "suspend sleep power", sub: I18n.tr("System"), glyph: "moon", run: function () { SessionActions.run("suspend"); } },
            { title: I18n.tr("Log Out"), kw: "logout exit session", sub: I18n.tr("System"), glyph: "logout", confirm: true, run: function () { SessionActions.run("logout"); } },
            { title: I18n.tr("Restart"), kw: "reboot restart", sub: I18n.tr("System"), glyph: "restart", confirm: true, run: function () { SessionActions.run("reboot"); } },
            { title: I18n.tr("Shut Down"), kw: "poweroff shutdown turn off", sub: I18n.tr("System"), glyph: "power", confirm: true, run: function () { SessionActions.run("shutdown"); } }
        ];
        var s = (q || "").trim().toLowerCase(), out = [];
        for (var i = 0; i < all.length; i++) {
            var a = all[i];
            if (s !== "" && a.title.toLowerCase().indexOf(s) < 0 && a.kw.indexOf(s) < 0 && a.sub.toLowerCase().indexOf(s) < 0) continue;
            out.push({
                title: a.title, sub: a.sub, section: "Actions", previewKind: "action",
                glyph: a.glyph, detail: a.title + " · " + a.sub, icon: "",
                confirm: a.confirm === true, stayOpen: a.stayOpen === true, run: a.run
            });
        }
        return out;
    }

    function makePathResult(p, isDir, section) {
        var name = p.substring(p.lastIndexOf("/") + 1) || p;
        var home = Quickshell.env("HOME") || "";
        var shortPath = (home !== "" && p.indexOf(home) === 0) ? ("~" + p.substring(home.length)) : p;
        var item = {
            title: name, sub: shortPath, section: section || "Files",
            previewKind: isDir ? "project" : "file",
            path: shortPath, fullPath: p, glyph: isDir ? "folder" : "doc", icon: "",
            run: function () { Quickshell.execDetached(["xdg-open", p]); }
        };
        if (isDir) {
            item.altLabel = I18n.tr("Terminal");
            item.altRun = function () { root.openFolderInTerminal(p); };
        }
        return item;
    }
    function devProjectItems(q, limit) {
        var s = (q || "").trim().toLowerCase(), hits = [], out = [], i;
        for (i = 0; i < devProjects.length; i++) {
            var d = devProjects[i], n = d.name.toLowerCase(), sc = 0;
            if (s === "") sc = 100 - i;
            else if (n === s) sc = 100;
            else if (n.indexOf(s) === 0) sc = 80;
            else if (n.indexOf(s) >= 0) sc = 50;
            if (sc > 0) hits.push({ d: d, sc: sc });
        }
        if (s !== "") hits.sort(function (a, b) { return b.sc - a.sc; });
        for (i = 0; i < hits.length && out.length < (limit || 6); i++)
            out.push(makePathResult(hits[i].d.path, hits[i].d.isDir, "Projects in ~/dev"));
        return out;
    }
    function filesModeItems(q) {
        var out = [], devs = devProjectItems(q, 8), seen = {}, i;
        for (i = 0; i < devs.length; i++) { out.push(devs[i]); seen[devs[i].fullPath] = true; }
        if ((q || "").trim() !== "") {
            for (i = 0; i < fileHits.length && out.length < 14; i++) {
                var h = fileHits[i];
                if (!h || !h.path || seen[h.path]) continue;
                seen[h.path] = true;
                out.push(makePathResult(h.path, h.isDir, "Files"));
            }
            if (out.length === 0)
                out.push({ title: fileSearchPending ? I18n.tr("Searching files\u2026") : I18n.tr("No matching files"), sub: "~/dev & Home", section: "Files", previewKind: "file", glyph: "folder", icon: "", run: function () {} });
        }
        return out.slice(0, 14);
    }
    function windowItems(q) {
        var out = [], s = (q || "").trim().toLowerCase(); if (!s) return out;
        var wins = Wm.windows || [];
        for (var i = 0; i < wins.length && out.length < 4; i++) {
            var w = wins[i], title = String(w.title || ""), cls = String(w.appId || ""), app = lookupApp(cls);
            var label = title || (app && app.name) || cls;
            if ((label + " " + cls + " " + (app ? app.name : "")).toLowerCase().indexOf(s) < 0) continue;
            var wid = String(w.id);
            out.push({
                title: label, sub: I18n.tr("Open Window"), section: "Open Windows",
                previewKind: "window", detail: (app ? app.name : cls),
                icon: app ? iconSrc(app.icon) : "", glyph: "layers",
                run: (function (id) { return function () { Wm.focusWindow(id); }; })(wid)
            });
        }
        return out;
    }
    function homeItems(q) {
        var raw = String(q || "").trim(), s = raw.toLowerCase(), out = [], i;
        if (raw === "") {
            var list = appList, usage = appUsage, used = [];
            for (i = 0; i < list.length; i++) if ((usage[list[i].id] || 0) > 0) used.push(list[i]);
            used.sort(function (a, b) { return (usage[b.id] || 0) - (usage[a.id] || 0); });
            if (used.length === 0) used = list.slice(0, 3);
            for (i = 0; i < used.length && i < 3; i++) {
                out.push({
                    title: used[i].name, sub: used[i].genericName || I18n.tr("Application"),
                    section: "Suggestions", previewKind: "app",
                    detail: used[i].comment || used[i].genericName || I18n.tr("Application"),
                    icon: iconSrc(used[i].icon), glyph: "",
                    run: (function (appEntry) { return function () { root.launchApp(appEntry); }; })(used[i])
                });
            }
            var devs = devProjectItems("", 4);
            for (i = 0; i < devs.length; i++) out.push(devs[i]);
            var acts = actionItems("");
            for (i = 0; i < acts.length && i < 2; i++) { acts[i].section = "Quick Actions"; out.push(acts[i]); }
            return out;
        }
        if (s.indexOf("file ") === 0 || s.indexOf("find ") === 0) {
            var fq = s.replace(/^(file|find)\s+/, "").trim();
            if (fq !== "" && fileQuery !== fq) updateFileSearch(fq);
            return filesModeItems(fq);
        }
        var cv = SpotMath.conversion(raw);
        if (cv) {
            out.push({
                title: cv.formatted, sub: I18n.tr("Conversion"), section: "Calculator",
                previewKind: "calc", formula: cv.formula, answer: cv.formatted, glyph: "link", icon: "",
                run: function () { Quickshell.execDetached(["wl-copy", cv.valueStr]); }
            });
        } else {
            var v = SpotMath.calcValue(raw.replace(/^=\s*/, ""));
            if (v !== null && (raw.charAt(0) === "=" || /[+*/%xX×÷^()]/.test(raw) || /\b(?:of|de|sqrt|sin|cos|tan|log|ln)\b/i.test(raw))) {
                var ans = String(Number(v.toPrecision(10)));
                out.push({
                    title: ans, sub: raw, section: "Calculator",
                    previewKind: "calc", formula: raw, answer: ans, glyph: "search", icon: "",
                    run: function () { Quickshell.execDetached(["wl-copy", ans]); }
                });
            }
        }
        if (/^(?:https?:\/\/|localhost:\d+|[a-z0-9-]+(?:\.[a-z0-9-]+)+\b)/i.test(raw) && !/\s/.test(raw) && raw.indexOf("..") < 0) {
            var url = /^https?:\/\//i.test(raw) ? raw : ("http" + (raw.indexOf("localhost") === 0 ? "" : "s") + "://" + raw);
            out.push({
                title: I18n.tr("Open ") + raw, sub: I18n.tr("Firefox"), section: "Web",
                previewKind: "web", detail: url, glyph: "link", icon: "",
                run: function () { root.openInFirefox(url); }
            });
        }
        var apps = searchApps(raw);
        for (i = 0; i < apps.length && i < 4; i++) {
            out.push({
                title: apps[i].name, sub: apps[i].genericName || I18n.tr("Application"),
                section: "Applications", previewKind: "app",
                detail: apps[i].comment || apps[i].genericName || I18n.tr("Application"),
                icon: iconSrc(apps[i].icon), glyph: "",
                run: (function (appEntry) { return function () { root.launchApp(appEntry); }; })(apps[i])
            });
        }
        var devHits = devProjectItems(raw, 4), seen = {};
        for (i = 0; i < devHits.length; i++) { out.push(devHits[i]); seen[devHits[i].fullPath] = true; }
        for (i = 0; i < fileHits.length && i < 4; i++) {
            var fh = fileHits[i];
            if (fh && fh.path && !seen[fh.path]) { seen[fh.path] = true; out.push(makePathResult(fh.path, fh.isDir, "Files")); }
        }
        var wins = windowItems(raw);
        for (i = 0; i < wins.length; i++) out.push(wins[i]);
        var acts2 = actionItems(raw);
        for (i = 0; i < acts2.length && i < 4; i++) out.push(acts2[i]);
        if (out.length > 0 && out[0].section !== "Calculator" && out[0].section !== "Web") {
            var fLow = out[0].title.toLowerCase();
            if (fLow === s || fLow.indexOf(s) === 0) out[0].section = "Top Hit";
        }
        out.push({
            title: I18n.tr("Search Google for \u201c") + raw + "\u201d", sub: I18n.tr("Firefox"),
            section: "Web", previewKind: "web", detail: "https://www.google.com/search?q=" + encodeURIComponent(raw),
            glyph: "search", icon: "",
            run: function () { root.openInFirefox("https://www.google.com/search?q=" + encodeURIComponent(raw)); }
        });
        return out.slice(0, 14);
    }

    readonly property bool spFull: spMode === "apps" || spMode === "clip" || spMode === "emoji"
    readonly property var spResults: spMode === "actions" ? actionItems(spPaintQuery)
                                    : (spMode === "files" ? filesModeItems(spPaintQuery)
                                    : (spMode === "clip" ? clipFiltered(spQuery)
                                    : (spMode === "home" ? homeItems(spPaintQuery) : [])))

    Timer { id: spResultDebounce; interval: 45; repeat: false; onTriggered: root.spPaintQuery = root.spQuery }
    Timer {
        id: spFocusTimer; interval: 40
        onTriggered: {
            if (root.spMode === "apps" && appsLoader.item) appsLoader.item.queryInput.forceActiveFocus();
            else if (root.spMode === "emoji" && emojiLoader.item) emojiLoader.item.queryInput.forceActiveFocus();
            else if (root.spMode === "clip") clipInput.forceActiveFocus();
            else spInput.forceActiveFocus();
        }
    }

    function openSpotlight(mode, calm) {
        openedAtMs = Date.now();
        spCalm = calm === true;
        spMode = mode || "home";
        spQuery = ""; spPaintQuery = ""; spSel = 0; armed = ""; spHoverLabel = "";
        spInput.text = ""; clipInput.text = "";
        if (appsLoader.item) appsLoader.item.queryInput.text = "";
        if (emojiLoader.item) emojiLoader.item.queryInput.text = "";
        updateFileSearch("");
        if (!devScanProc.running) devScanProc.running = true;
        if (spMode === "clip") clipRefresh();
        spotOpen = true;
        spFocusTimer.restart();
    }
    function setMode(m) {
        spMode = m; spQuery = ""; spPaintQuery = ""; spSel = 0; armed = ""; spHoverLabel = "";
        spInput.text = ""; clipInput.text = "";
        if (appsLoader.item) appsLoader.item.queryInput.text = "";
        if (emojiLoader.item) emojiLoader.item.queryInput.text = "";
        if (m === "clip") clipRefresh();
        spFocusTimer.restart();
    }
    function closeSpotlight() {
        if (!spotOpen) return;
        spotOpen = false;
        dismissed();
    }
    function handleEscape() {
        if (spQuery !== "") { spInput.text = ""; clipInput.text = ""; spQuery = ""; }
        else if (spMode !== "home") setMode("home");
        else closeSpotlight();
    }
    function activate(i) {
        var it = spResults[i];
        if (!it) return;
        if (it.confirm === true && armed !== it.title) { armed = it.title; return; }
        if (!it.stayOpen) closeSpotlight();
        if (it.run) it.run();
    }
    function handleKey(ev) {
        var k = ev.key, n = spResults.length;
        if (k === Qt.Key_Escape) { handleEscape(); ev.accepted = true; }
        else if (!spFull && (k === Qt.Key_Tab || k === Qt.Key_Backtab)) {
            var modes = ["home", "files", "actions"];
            var idx = Math.max(0, modes.indexOf(spMode));
            setMode(modes[(idx + (k === Qt.Key_Tab ? 1 : modes.length - 1)) % modes.length]);
            ev.accepted = true;
        } else if (k === Qt.Key_Down) {
            spHover = false; if (n > 0) spSel = (Math.min(spSel, n - 1) + 1) % n;
            ev.accepted = true;
        } else if (k === Qt.Key_Up) {
            spHover = false; if (n > 0) spSel = (Math.min(spSel, n - 1) - 1 + n) % n;
            ev.accepted = true;
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            if (spMode === "clip" && (ev.modifiers & Qt.ShiftModifier) && n > 0) {
                var cIt = spResults[Math.min(spSel, n - 1)];
                closeSpotlight();
                clipPick(cIt, false);
            } else if (!spFull && (ev.modifiers & Qt.ShiftModifier) && n > 0) {
                var aIt = spResults[Math.min(spSel, n - 1)];
                if (aIt && aIt.altRun) { closeSpotlight(); aIt.altRun(); }
                else activate(Math.min(spSel, n - 1));
            } else if (n > 0) activate(Math.min(spSel, n - 1));
            ev.accepted = true;
        }
    }

    onOpenRequestedChanged: {
        if (openRequested) { if (!spotOpen) openSpotlight("home", false); }
        else if (spotOpen) spotOpen = false;
    }

    IpcHandler {
        target: "gokko-spotlight-spotlight-internal"
        function toggle(): void { if (root.spotOpen) root.closeSpotlight(); else { root.openModeRequested(); root.openSpotlight("home", false); } }
        function clipboard(): void { root.openModeRequested(); root.openSpotlight("clip", true); }
        function emoji(): void { root.openModeRequested(); root.openSpotlight("emoji", true); }
        function apps(): void { root.openModeRequested(); root.openSpotlight("apps", false); }
        function files(): void { root.openModeRequested(); root.openSpotlight("files", false); }
    }

    PanelWindow {
        id: spotWin
        screen: root.hostScreen
        readonly property bool openish: root.spotOpen || spot.vis > 0.002
        visible: openish
        mask: Region { item: spotWin.openish ? spotRoot : spotNoInput }
        Item { id: spotNoInput; width: 0; height: 0 }
        anchors { left: true; right: true; top: true; bottom: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "macspot"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: (!root.perfNoFocus && root.spotOpen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        Item {
            id: spotRoot
            anchors.fill: parent

            // Click outside Spotlight closes it
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: root.closeSpotlight()
            }

            // Lightweight blurred wallpaper backdrop for Liquid Glass refraction
            Image {
                id: wallBg
                anchors.fill: parent
                visible: false
                source: root.wallpaperUrl
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
            }
            ShaderEffectSource {
                id: spSrc
                sourceItem: wallBg.status === Image.Ready ? wallBg : wallFallback
                hideSource: true
                live: spotWin.openish
                visible: false
                sourceRect: Qt.rect(spot.x - 96, spot.y - 96, spot.width + 192, spot.height + 192)
            }
            Rectangle {
                id: wallFallback
                anchors.fill: parent
                visible: false
                color: root.panelDarkMode ? "#1A1D24" : "#E6EAF2"
            }
            MultiEffect {
                id: spBlurFx
                source: spSrc
                width: spSrc.sourceRect.width; height: spSrc.sourceRect.height
                blurEnabled: true; blurMax: 48; blur: 0.75
                autoPaddingEnabled: false; visible: false
            }
            ShaderEffectSource { id: spBlur; sourceItem: spBlurFx; live: spotWin.openish; visible: false }

            Item {
                id: spot
                z: 10
                width: 720
                readonly property real curPanelH: root.spMode === "apps" && appsLoader.item ? appsLoader.item.height
                                                : (root.spMode === "emoji" && emojiLoader.item ? emojiLoader.item.height
                                                : (root.spMode === "clip" ? clipPanel.height : 0))
                height: root.spFull ? curPanelH : (resPanel.visible ? resPanel.y + resPanel.height : spRow.height)
                x: Math.round((spotRoot.width - width) / 2)
                y: Math.max(48, Math.round(root.spFull ? (spotRoot.height * 0.5 - curPanelH / 2) : (spotRoot.height * 0.28 - 24)))

                property real vis: root.spotOpen ? 1 : 0
                Behavior on vis { NumberAnimation { duration: root.spCalm ? 140 : 160; easing.type: Easing.OutCubic } }
                opacity: vis
                scale: root.spotOpen ? 1 : (root.spCalm ? 0.98 : 0.95)
                Behavior on scale { NumberAnimation { duration: root.spCalm ? 140 : 170; easing.type: Easing.OutQuint } }
                transformOrigin: Item.Center

                onVisChanged: {
                    if (root.perfNoFocus && vis >= 0.99 && root.openedAtMs > 0) {
                        console.log("[gokko-spotlight-perf] visible_ms=" + (Date.now() - root.openedAtMs) + " monitor=" + (root.hostScreen ? root.hostScreen.name : "") + " wallStatus=" + wallBg.status);
                        root.openedAtMs = 0;
                    }
                }

                // Helper component: single-pane Liquid Glass slab
                component SpotGlass: Item {
                    id: sg
                    property real cornerR: 26
                    property real strength: 0.95
                    property real tint: root.glassOpacity
                    property real shadowAmt: 0.14
                    readonly property real pad: 10
                    function framePos() {
                        var px = 0, py = 0, it = sg;
                        while (it && it !== spotRoot) { px += it.x; py += it.y; it = it.parent; }
                        return Qt.point(px, py);
                    }
                    readonly property point fp: framePos()
                    Rectangle {
                        visible: !root.liquidActive
                        anchors.fill: parent; radius: sg.cornerR
                        color: root.panelDarkMode ? Qt.rgba(0.11, 0.11, 0.13, 0.86) : Qt.rgba(0.96, 0.96, 0.98, 0.88)
                    }
                    ShaderEffect {
                        visible: root.liquidActive
                        x: -sg.pad; y: -sg.pad
                        width: sg.width + 2 * sg.pad; height: sg.height + 2 * sg.pad
                        fragmentShader: root.glassShaderUrl
                        property variant src: spBlur
                        property vector2d itemSize: Qt.vector2d(width, height)
                        property vector2d glassSize: Qt.vector2d(sg.width, sg.height)
                        property vector2d srcSize: Qt.vector2d(spSrc.sourceRect.width, spSrc.sourceRect.height)
                        property vector2d srcOffset: Qt.vector2d(sg.fp.x - sg.pad - spSrc.sourceRect.x, sg.fp.y - sg.pad - spSrc.sourceRect.y)
                        property real pad: sg.pad
                        property real radius: sg.cornerR
                        property real bezel: Math.min(sg.height * 0.34, 22)
                        property real thickness: 26 * root.glassLiquid * sg.strength
                        property real dispersion: 0.055 * root.glassLiquid * sg.strength
                        property real magnify: 0.045 * root.glassLiquid * sg.strength
                        property real rim: Math.max(0.45, root.glassRim)
                        property real grain: root.glassGrain * 0.25
                        property real blurPx: 14.0
                        property real tintMix: sg.tint * 0.45
                        property real saturation: 1.32
                        property real dark: root.panelDarkMode ? 1 : 0
                        property real debug: 0
                        property real shadowAmt: sg.shadowAmt
                        property real flatInner: 1
                        property real rimTint: 1
                        property real ringW: 0.9
                    }
                    MacParts.MenuBorder {
                        amount: 0.5; anchors.fill: parent; cornerR: sg.cornerR
                        dark: root.panelDarkMode; tint: panelPal.borderTint
                    }
                }

                // ── Top Search Pill + 5 Mode Buttons ──
                Row {
                    id: spRow
                    spacing: 12
                    opacity: !root.spFull ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                    Item {
                        id: spPill
                        width: spot.width - 5 * 60
                        height: 48
                        SpotGlass { anchors.fill: parent; cornerR: 24; shadowAmt: 0.08 }
                        MacParts.MacGlyph { x: 18; anchors.verticalCenter: parent.verticalCenter; width: 18; height: 18; kind: "search"; color: panelPal.fg2 }
                        MacParts.MorphText {
                            x: 49; width: spInput.width; anchors.verticalCenter: parent.verticalCenter
                            visible: spInput.text === ""
                            animateWidth: false; duration: 360; blurMax: 32
                            text: root.spHoverLabel !== "" ? root.spHoverLabel
                                : (root.spMode === "files" ? I18n.tr("Files & ~/dev Projects")
                                : (root.spMode === "actions" ? I18n.tr("Actions & Settings") : I18n.tr("Spotlight Search")))
                            color: panelPal.fg2; font.family: root.fontForWeight(Font.Normal, panelPal.fam); font.pixelSize: 17; elide: Text.ElideRight
                        }
                        TextInput {
                            id: spInput
                            x: 46; width: parent.width - 64; anchors.verticalCenter: parent.verticalCenter
                            clip: true; color: panelPal.fg
                            selectionColor: root.accent; selectedTextColor: "white"
                            font.family: root.fontForWeight(Font.Normal, panelPal.fam); font.pixelSize: 17
                            onTextChanged: {
                                if (!root.spFull) {
                                    root.spQuery = text; root.spSel = 0; root.armed = "";
                                    if (text === "") { root.spPaintQuery = ""; spResultDebounce.stop(); root.updateFileSearch(""); }
                                    else {
                                        spResultDebounce.restart();
                                        var fq = text.replace(/^(file|find)\s+/i, "").trim();
                                        if (/^(file|find)\s+/i.test(text) || root.spMode === "files" || fq.length >= 2) root.updateFileSearch(fq);
                                        else root.updateFileSearch("");
                                    }
                                }
                            }
                            Keys.onPressed: ev => root.handleKey(ev)
                        }
                    }

                    Repeater {
                        model: [
                            { k: "appstore", id: "apps", label: I18n.tr("Apps") },
                            { k: "folder", id: "files", label: I18n.tr("Files") },
                            { k: "layers", id: "actions", label: I18n.tr("Actions") },
                            { k: "clipboard", id: "clip", label: I18n.tr("Clipboard") },
                            { k: "smile", id: "emoji", label: I18n.tr("Emoji") }
                        ]
                        delegate: Item {
                            id: mbtn
                            required property var modelData
                            readonly property bool isOn: root.spMode === modelData.id
                            width: 48; height: 48
                            scale: mbMa.pressed ? 0.88 : 1
                            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack; easing.overshoot: 2.5 } }
                            SpotGlass { anchors.fill: parent; cornerR: 24; shadowAmt: 0.14 }
                            Rectangle {
                                anchors.fill: parent; radius: 24
                                color: mbtn.isOn ? "white" : (mbMa.containsMouse ? panelPal.hover : "transparent")
                                Behavior on color { ColorAnimation { duration: 160 } }
                            }
                            MacParts.MacGlyph {
                                anchors.centerIn: parent; width: 22; height: 22
                                kind: mbtn.modelData.k
                                color: mbtn.isOn ? root.accent : panelPal.fg
                            }
                            MouseArea {
                                id: mbMa; anchors.fill: parent; hoverEnabled: true
                                onEntered: root.spHoverLabel = mbtn.modelData.label
                                onExited: if (root.spHoverLabel === mbtn.modelData.label) root.spHoverLabel = ""
                                onClicked: root.setMode(mbtn.isOn ? "home" : mbtn.modelData.id)
                            }
                        }
                    }
                }

                // ── macOS Split View: Grouped Results + Preview Inspector ──
                Item {
                    id: resPanel
                    y: spRow.height + 10
                    width: spot.width
                    readonly property var items: root.spFull ? [] : root.spResults
                    readonly property int selIdx: items.length > 0 ? Math.max(0, Math.min(root.spSel, items.length - 1)) : -1
                    readonly property var selItem: selIdx >= 0 ? items[selIdx] : null
                    readonly property int maxH: Math.min(410, Math.max(220, Math.round(spotRoot.height * 0.52)))
                    readonly property int listW: 382
                    opacity: (!root.spFull && items.length > 0) ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                    height: items.length > 0 ? Math.min(maxH, Math.max(196, spList.contentHeight + 16)) : 196
                    Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }

                    SpotGlass { anchors.fill: parent; cornerR: 26; shadowAmt: 0.14 }

                    ListView {
                        id: spList
                        x: 8; y: 8; width: resPanel.listW - 12; height: parent.height - 16
                        clip: true; boundsBehavior: Flickable.StopAtBounds
                        model: resPanel.items
                        Connections {
                            target: root
                            function onSpSelChanged() {
                                if (root.spHover) { root.spHover = false; return; }
                                if (!root.spFull && resPanel.items.length > 0) spList.positionViewAtIndex(resPanel.selIdx, ListView.Contain);
                            }
                        }
                        delegate: Column {
                            id: rrCol
                            required property var modelData
                            required property int index
                            readonly property bool showSec: {
                                if (!modelData || !modelData.section) return false;
                                if (index === 0) return true;
                                var prev = resPanel.items[index - 1];
                                return !prev || prev.section !== modelData.section;
                            }
                            width: spList.width
                            Item {
                                visible: rrCol.showSec; width: parent.width; height: rrCol.index === 0 ? 20 : 24
                                Text {
                                    x: 10; anchors.bottom: parent.bottom; anchors.bottomMargin: 4
                                    text: (rrCol.modelData && rrCol.modelData.section) ? I18n.tr(rrCol.modelData.section).toUpperCase() : ""
                                    color: panelPal.fg3; font.family: root.fontForWeight(Font.DemiBold, panelPal.fam); font.pixelSize: 10; font.letterSpacing: 0.6; font.weight: Font.DemiBold
                                }
                            }
                            Item {
                                id: rr
                                readonly property string ico: (rrCol.modelData && rrCol.modelData.icon) ? String(rrCol.modelData.icon) : ""
                                readonly property bool sel: rrCol.index === resPanel.selIdx
                                readonly property bool armedNow: rrCol.modelData && rrCol.modelData.confirm === true && root.armed === rrCol.modelData.title
                                width: parent.width; height: 44
                                Rectangle {
                                    anchors.fill: parent; radius: 14
                                    color: rr.armedNow ? "#FF453A" : root.accent
                                    opacity: rr.sel ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 75 } }
                                }
                                Item {
                                    x: 10; anchors.verticalCenter: parent.verticalCenter; width: 28; height: 28
                                    Image { visible: rr.ico !== ""; anchors.fill: parent; source: rr.ico; sourceSize: Qt.size(64, 64); fillMode: Image.PreserveAspectFit; asynchronous: true; smooth: true }
                                    MacParts.MacGlyph { visible: rr.ico === ""; anchors.centerIn: parent; width: 18; height: 18; kind: (rrCol.modelData && rrCol.modelData.glyph) ? rrCol.modelData.glyph : ""; color: rr.sel ? "white" : panelPal.fg }
                                }
                                Text {
                                    x: 46; anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 46 - (subLbl.visible ? Math.min(110, subLbl.implicitWidth + 14) : 10); elide: Text.ElideRight
                                    text: rr.armedNow ? I18n.tr("Press Return again to confirm") : (rrCol.modelData ? rrCol.modelData.title : "")
                                    color: rr.sel ? "white" : panelPal.fg
                                    font.family: root.fontForWeight(rr.sel ? Font.Medium : Font.Normal, panelPal.fam); font.pixelSize: 13; font.weight: rr.sel ? Font.Medium : Font.Normal
                                }
                                Text {
                                    id: subLbl
                                    visible: !rr.armedNow && rrCol.modelData && rrCol.modelData.sub !== undefined && rrCol.modelData.sub !== ""
                                    anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(100, implicitWidth); elide: Text.ElideRight; horizontalAlignment: Text.AlignRight
                                    text: rrCol.modelData ? (rrCol.modelData.sub || "") : ""
                                    color: rr.sel ? Qt.rgba(1, 1, 1, 0.82) : panelPal.fg2
                                    font.family: root.fontForWeight(Font.Normal, panelPal.fam); font.pixelSize: 11
                                }
                                MouseArea {
                                    anchors.fill: parent; hoverEnabled: true
                                    onEntered: if (root.spSel !== rrCol.index) { root.spHover = true; root.spSel = rrCol.index; }
                                    onClicked: root.activate(rrCol.index)
                                }
                            }
                        }
                    }

                    Rectangle { x: resPanel.listW; y: 12; width: 1; height: parent.height - 24; color: panelPal.sep }

                    Item {
                        id: spPreview
                        x: resPanel.listW + 1; y: 8
                        width: parent.width - resPanel.listW - 9; height: parent.height - 16
                        readonly property var cur: resPanel.selItem
                        readonly property string kind: cur && cur.previewKind ? cur.previewKind : ""

                        Column {
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: previewFooter.top
                            anchors.margins: 14; anchors.topMargin: 16; spacing: 10
                            visible: spPreview.cur !== null

                            Column {
                                visible: spPreview.kind === "calc"; width: parent.width; spacing: 6
                                Rectangle {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: calcTag.implicitWidth + 14; height: 20; radius: 10
                                    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, root.panelDarkMode ? 0.24 : 0.14)
                                    Text { id: calcTag; anchors.centerIn: parent; text: (spPreview.cur && spPreview.cur.sub) ? spPreview.cur.sub : I18n.tr("Calculator"); color: root.accent; font.family: root.fontForWeight(Font.DemiBold, panelPal.fam); font.pixelSize: 10; font.weight: Font.DemiBold }
                                }
                                Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WrapAnywhere; text: (spPreview.cur && spPreview.cur.answer) ? spPreview.cur.answer : ""; color: panelPal.fg; font.family: root.fontForWeight(Font.DemiBold, panelPal.fam); font.pixelSize: 28; font.weight: Font.DemiBold }
                                Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; text: (spPreview.cur && spPreview.cur.formula) ? ("= " + spPreview.cur.formula) : ""; color: panelPal.fg2; font.family: root.fontForWeight(Font.Normal, panelPal.fam); font.pixelSize: 12 }
                            }

                            Column {
                                visible: spPreview.kind !== "calc"; width: parent.width; spacing: 10
                                Item {
                                    anchors.horizontalCenter: parent.horizontalCenter; width: 62; height: 62
                                    Rectangle { visible: !spPreview.cur || !spPreview.cur.icon || spPreview.cur.icon === ""; anchors.fill: parent; radius: 16; color: root.panelDarkMode ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.06); border.width: 1; border.color: panelPal.sep }
                                    Image { visible: spPreview.cur && spPreview.cur.icon && spPreview.cur.icon !== ""; anchors.fill: parent; source: (spPreview.cur && spPreview.cur.icon) ? spPreview.cur.icon : ""; sourceSize: Qt.size(128, 128); fillMode: Image.PreserveAspectFit; asynchronous: true; smooth: true }
                                    MacParts.MacGlyph { visible: !spPreview.cur || !spPreview.cur.icon || spPreview.cur.icon === ""; anchors.centerIn: parent; width: 28; height: 28; kind: (spPreview.cur && spPreview.cur.glyph) ? spPreview.cur.glyph : "search"; color: spPreview.kind === "project" ? root.accent : panelPal.fg }
                                }
                                Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.Wrap; text: spPreview.cur ? spPreview.cur.title : ""; color: panelPal.fg; font.family: root.fontForWeight(Font.DemiBold, panelPal.fam); font.pixelSize: 15; font.weight: Font.DemiBold }
                                Text {
                                    width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WrapAnywhere; maximumLineCount: 3; elide: Text.ElideMiddle
                                    text: !spPreview.cur ? "" : (spPreview.cur.path || spPreview.cur.detail || spPreview.cur.sub || "")
                                    color: panelPal.fg2; font.family: root.fontForWeight(Font.Normal, panelPal.fam); font.pixelSize: 11
                                }
                            }
                        }

                        Item {
                            id: previewFooter
                            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 12; height: 34
                            visible: spPreview.cur !== null
                            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: panelPal.sep }
                            Row {
                                anchors.centerIn: parent; anchors.verticalCenterOffset: 4; spacing: 8
                                Rectangle {
                                    width: priTxt.implicitWidth + 18; height: 24; radius: 8
                                    color: priMa.containsMouse ? root.accent : (root.panelDarkMode ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.08))
                                    Text {
                                        id: priTxt; anchors.centerIn: parent
                                        text: spPreview.kind === "calc" ? I18n.tr("Copy (\u21b5)") : (spPreview.kind === "web" ? I18n.tr("Firefox (\u21b5)") : (spPreview.kind === "window" ? I18n.tr("Focus (\u21b5)") : (spPreview.kind === "action" ? I18n.tr("Run (\u21b5)") : I18n.tr("Open (\u21b5)"))))
                                        color: priMa.containsMouse ? "white" : panelPal.fg; font.family: root.fontForWeight(Font.Medium, panelPal.fam); font.pixelSize: 11; font.weight: Font.Medium
                                    }
                                    MouseArea { id: priMa; anchors.fill: parent; hoverEnabled: true; onClicked: root.activate(resPanel.selIdx) }
                                }
                                Rectangle {
                                    visible: spPreview.cur && spPreview.cur.altRun !== undefined
                                    width: altTxt.implicitWidth + 18; height: 24; radius: 8
                                    color: altMa.containsMouse ? root.accent : (root.panelDarkMode ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.08))
                                    Text {
                                        id: altTxt; anchors.centerIn: parent
                                        text: (spPreview.cur && spPreview.cur.altLabel) ? (spPreview.cur.altLabel + " (\u21e7\u21b5)") : ""
                                        color: altMa.containsMouse ? "white" : panelPal.fg; font.family: root.fontForWeight(Font.Medium, panelPal.fam); font.pixelSize: 11; font.weight: Font.Medium
                                    }
                                    MouseArea {
                                        id: altMa; anchors.fill: parent; hoverEnabled: true
                                        onClicked: { if (spPreview.cur && spPreview.cur.altRun) { var fn = spPreview.cur.altRun; root.closeSpotlight(); fn(); } }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── Clipboard Panel ──
                Item {
                    id: clipPanel
                    width: spot.width
                    readonly property var items: root.spMode === "clip" ? root.spResults : []
                    readonly property int rowH: 56
                    readonly property int shown: Math.min(items.length, 7)
                    height: 64 + (items.length > 0 ? shown * rowH + 14 : 118)
                    opacity: root.spMode === "clip" ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 180 } }
                    SpotGlass { anchors.fill: parent; cornerR: 32; shadowAmt: 0.22 }

                    Item {
                        x: 20; width: parent.width - 40; height: 64
                        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 34; height: 34; radius: 10; color: root.accent; MacParts.MacGlyph { anchors.centerIn: parent; width: 20; height: 20; kind: "clipboard"; color: "white" } }
                        Text { id: clipLbl; x: 46; anchors.verticalCenter: parent.verticalCenter; text: I18n.tr("Clipboard"); color: panelPal.fg; font.family: root.fontForWeight(Font.Medium, panelPal.fam); font.pixelSize: 24; font.weight: Font.Medium }
                        TextInput {
                            id: clipInput; x: clipLbl.x + clipLbl.width + 14; width: parent.width - x - 48; anchors.verticalCenter: parent.verticalCenter
                            clip: true; color: panelPal.fg; selectionColor: root.accent; selectedTextColor: "white"
                            font.family: root.fontForWeight(Font.Normal, panelPal.fam); font.pixelSize: 24
                            onTextChanged: if (root.spMode === "clip") { root.spQuery = text; root.spSel = 0; }
                            Keys.onPressed: ev => root.handleKey(ev)
                        }
                    }
                    ListView {
                        x: 8; y: 64; width: parent.width - 16; height: clipPanel.shown * clipPanel.rowH
                        visible: clipPanel.items.length > 0; clip: true; boundsBehavior: Flickable.StopAtBounds
                        model: clipPanel.items
                        delegate: Item {
                            id: cr
                            required property var modelData
                            required property int index
                            readonly property bool sel: index === Math.min(root.spSel, clipPanel.items.length - 1)
                            width: ListView.view.width; height: clipPanel.rowH
                            Rectangle { anchors.fill: parent; anchors.topMargin: 2; anchors.bottomMargin: 2; radius: 16; color: root.accent; opacity: cr.sel ? 1 : 0 }
                            Rectangle { x: 14; anchors.verticalCenter: parent.verticalCenter; width: 36; height: 36; radius: 10; color: cr.sel ? Qt.rgba(1, 1, 1, 0.22) : (root.panelDarkMode ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.06))
                                MacParts.MacGlyph { visible: cr.modelData.kind !== "image" && cr.modelData.kind !== "color"; anchors.centerIn: parent; width: 20; height: 20; kind: cr.modelData.kind === "url" ? "link" : "doc"; color: cr.sel ? "white" : panelPal.fg2 }
                                Image { visible: cr.modelData.kind === "image"; anchors.fill: parent; source: cr.modelData.thumb || ""; fillMode: Image.PreserveAspectCrop; asynchronous: true }
                            }
                            Text { x: 62; y: 9; width: parent.width - 118; elide: Text.ElideRight; text: cr.modelData.title; color: cr.sel ? "white" : panelPal.fg; font.family: panelPal.fam; font.pixelSize: 14 }
                            Text { x: 62; y: 31; width: parent.width - 118; elide: Text.ElideRight; text: cr.modelData.sub; color: cr.sel ? Qt.rgba(1, 1, 1, 0.8) : panelPal.fg2; font.family: panelPal.fam; font.pixelSize: 12 }
                            MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: root.spSel = cr.index; onClicked: root.activate(cr.index) }
                        }
                    }
                    Text {
                        visible: clipPanel.items.length === 0
                        x: 20; y: 64; width: parent.width - 40; height: 118
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                        text: root.clipState === "missing" ? I18n.tr("Install cliphist & wl-clipboard") : (root.clipLoading ? I18n.tr("Loading\u2026") : I18n.tr("Nothing copied yet"))
                        color: panelPal.fg2; font.family: panelPal.fam; font.pixelSize: 14
                    }
                }

                // ── Lazy-loaded Emoji & Apps Panels (zero cold-start cost) ──
                Loader {
                    id: emojiLoader
                    width: spot.width
                    active: root.spMode === "emoji"
                    visible: active
                    sourceComponent: Item {
                        height: emp.height
                        SpotGlass { anchors.fill: parent; cornerR: 32; shadowAmt: 0.22 }
                        MacParts.SpotEmojiPanel {
                            id: emp; width: parent.width
                            host: root; pal: panelPal; glassSrc: spBlur
                            accent: root.accent; borderColor: panelPal.borderTint
                            dark: root.panelDarkMode; emojiFont: root.emojiFont; clipAutoPaste: root.clipAutoPaste
                        }
                        Component.onCompleted: Qt.callLater(function () { emp.queryInput.forceActiveFocus(); })
                    }
                }
                Loader {
                    id: appsLoader
                    width: spot.width
                    active: root.spMode === "apps"
                    visible: active
                    sourceComponent: Item {
                        height: ap.height
                        SpotGlass { anchors.fill: parent; cornerR: 32; shadowAmt: 0.22 }
                        MacParts.SpotAppsPanel {
                            id: ap; width: parent.width
                            host: root; pal: panelPal; accent: root.accent
                        }
                        Component.onCompleted: Qt.callLater(function () { ap.queryInput.forceActiveFocus(); })
                    }
                }
            }
        }
    }
}
