# gokko-custom (`zSnowww/gokko-custom`)

Personal fork/customization of the [Gokko](https://github.com/Ryoku-dev/ryostore/tree/main/barstyles/gokko) / [MacShell](https://github.com/0-ss/MacShell) Ryoku barstyle (MIT License, see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md)).

## Why this setup keeps Ryoku compatibility & survives Store updates

Ryoku's shell core (`~/.config/quickshell/shell/shell.qml`, `services/BarProducts.qml`, `services/Config.qml`) keys full-desktop ownership (`gokkoRunning`, `isFrameFamily`, notification/OSD handoff, `gokkoWidgets`) directly on the `"gokko"` ID.

To avoid both colliding with Ryoku's native surfaces and losing local edits when Ryoku Store updates Gokko:

1. Source code lives here in its own Git repository (`~/gokko-custom`), outside `~/.local/share/ryoku/`.
2. `./sync-ryoku.sh` deploys runtime files into an **isolated view folder** (`~/.local/state/ryoku/store/barstyle-views/gokko/<sha256("zsnow-gokko-custom")>`) and points `~/.local/state/ryoku/store/barstyles.json` (`id: "gokko"`) at it.
3. Official Store installs/updates never overwrite `~/gokko-custom`; if an update replaces `barstyles.json`, running `./sync-ryoku.sh` reactivates this build immediately.

## Included customizations (beyond 0.3.4 base)

- **Wi-Fi & NetworkManager**: decode `nmcli -g` escaped SSIDs, strict SSID matching, UUID disconnect, Nearby/Known Networks split, inline two-step Forget confirmation.
- **Bluetooth**: BlueZ 5.87+ per-bearer status detection (`Number(...) > 0`), strip `bluetoothctl` ANSI escapes, inline two-step Forget (`bluetoothctl remove`), battery % readout (`Connected · XX%`), `My Devices` / `Other Devices` split with device badges.
- **Control Center**:
  - Click Wi-Fi/Bluetooth tiles to open their subpages inside Control Center; click `Sound` tile header to pick default PipeWire audio output (`ccSoundPage`).
  - Right-click anywhere inside Control Center without closing it (`ccCtx` context menu): `Edit Controls`, `Show in Menu Bar` (`wifi` / `bluetooth` / `volume`), `Control Center Settings…`.
  - **Edit Controls mode only**: drag-and-drop free-cell placement (`ccPos`), corner `ResizeKnob` drag-resizing (`ResizeKnob.qml`), and right-click resize / `Remove Control` options (`ccSizes`).

## Usage

```bash
./sync-ryoku.sh          # Sync files to isolated view + update barstyles.json + reload ryoku-shell
./sync-ryoku.sh --lint   # Also run qmllint checks before syncing
```
