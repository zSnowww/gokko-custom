#!/usr/bin/env python3
"""Passive BlueZ BLE monitor for Apple Proximity Pairing (0x07) beacons.

Runs alongside podctld without touching Classic L2CAP (PSM 0x1001). Uses
podctl's saved IRK keys (~/.local/state/podctl/keys-*) to match rotating BLE
RPAs and emits newline-delimited JSON objects with coarse battery/charging
telemetry from Apple Continuity type 0x07 frames.
"""

import ctypes
import glob
import json
import os
import re
import signal
import sys
import time

import dbus
import dbus.mainloop.glib
import dbus.service
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from gi.repository import GLib
try:
    from gi.repository import GLibUnix
except ImportError:
    GLibUnix = None


STATE_DIR = os.path.expanduser(
    os.path.join(os.environ.get("XDG_STATE_HOME", "~/.local/state"), "podctl")
)
MON_BASE = "/com/gokko/podble"
MON_PATH = f"{MON_BASE}/mon0"
TARGET_MAC = sys.argv[1].upper() if len(sys.argv) > 1 else ""


def load_keys():
    """Load (mac_upper, irk_bytes) entries from podctl state files."""
    entries = []
    for path in sorted(glob.glob(os.path.join(STATE_DIR, "keys-*"))):
        name = os.path.basename(path)
        hex_mac = name[5:].upper()
        mac = ":".join(hex_mac[i : i + 2] for i in range(0, 12, 2)) if len(hex_mac) == 12 else ""
        if TARGET_MAC and mac and mac != TARGET_MAC:
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                txt = f.read()
        except OSError:
            continue
        m_irk = re.search(r"irk\s+([0-9a-fA-F]{32})", txt)
        if not m_irk:
            continue
        entries.append((mac, bytes.fromhex(m_irk.group(1))))
    return entries


def rpa_matches(addr, irk):
    """Return True if BLE Resolvable Private Address matches IRK via BT Core ah()."""
    parts_s = addr.split(":")
    if len(parts_s) != 6:
        return False
    try:
        parts = [int(x, 16) for x in parts_s]
    except ValueError:
        return False
    if (parts[0] & 0xC0) != 0x40:
        return False
    prand = bytes(parts[0:3])
    ahash = bytes(parts[3:6])
    r_pad = b"\x00" * 13 + prand
    for key in (irk, irk[::-1]):
        enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
        out = enc.update(r_pad) + enc.finalize()
        if out[-3:] == ahash:
            return True
    return False


def decode_continuity_07(raw):
    """Parse Apple Continuity 0x07 Proximity Pairing header nibbles & charging."""
    if len(raw) < 9 or raw[0] != 0x07 or raw[1] < 0x13:
        return None
    # Paired (0x01) or pairing (0x00) proximity pairing message
    if raw[2] not in (0x00, 0x01):
        return None
    utp = raw[5]
    batt = raw[6]
    flags_case = raw[7]
    status = raw[8]

    hi_bat = (batt >> 4) & 0x0F
    lo_bat = batt & 0x0F
    case_nib = flags_case & 0x0F
    chg_nib = (flags_case >> 4) & 0x0F

    def pct(n):
        return (n * 10) if 0 <= n <= 10 else -1

    # Verified empirically on AirPods Pro 3 (0x2027) captures:
    # hi nibble is Left, lo nibble is Right regardless of utp 0x20 bit;
    # status_byte bit 3 (0x08) is 0 when lid is open (0x33) and 1 when closed (0x3b).
    left_pct, right_pct = pct(hi_bat), pct(lo_bat)
    left_chg = bool(chg_nib & 0x01)
    right_chg = bool(chg_nib & 0x02)
    case_pct = pct(case_nib)
    case_chg = bool(chg_nib & 0x04)
    lid_open = (status & 0x08) == 0

    return {
        "kind": "ble",
        "left": left_pct,
        "right": right_pct,
        "case": case_pct,
        "left_charging": left_chg,
        "right_charging": right_chg,
        "case_charging": case_chg,
        "lid_open": lid_open,
        "utp": utp,
        "status_byte": status,
        "ts": int(time.time()),
    }


def main():
    # Exit cleanly when parent shell (Quickshell) reloads or exits
    try:
        libc = ctypes.CDLL("libc.so.6")
        libc.prctl(1, signal.SIGTERM)
    except Exception:
        pass
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    loop = GLib.MainLoop()

    state = {
        "keys": load_keys(),
        "keys_ts": time.monotonic(),
        "matched_paths": {},  # object_path -> known_mac
        "last_emit": None,
    }

    def emit(payload, dev_mac):
        payload["address"] = dev_mac
        sig = (
            payload["address"],
            payload["left"],
            payload["right"],
            payload["case"],
            payload["left_charging"],
            payload["right_charging"],
            payload["case_charging"],
            payload["status_byte"],
        )
        now = time.monotonic()
        if state["last_emit"] and state["last_emit"][0] == sig and (now - state["last_emit"][1]) < 3.0:
            return
        state["last_emit"] = (sig, now)
        sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    def refresh_keys_if_stale():
        now = time.monotonic()
        if now - state["keys_ts"] >= 20.0:
            state["keys"] = load_keys()
            state["keys_ts"] = now

    def resolve_mac(path, addr_hint=""):
        if path in state["matched_paths"]:
            return state["matched_paths"][path]
        refresh_keys_if_stale()
        addr = addr_hint.upper()
        if not addr:
            try:
                props = dbus.Interface(bus.get_object("org.bluez", path), "org.freedesktop.DBus.Properties")
                addr = str(props.Get("org.bluez.Device1", "Address")).upper()
            except Exception:
                return ""
        for known_mac, irk in state["keys"]:
            if known_mac and addr == known_mac:
                state["matched_paths"][path] = known_mac
                return known_mac
            if rpa_matches(addr, irk):
                state["matched_paths"][path] = known_mac or addr
                return state["matched_paths"][path]
        return ""

    def handle_mfg_data(path, mfg_dict, addr_hint=""):
        if not mfg_dict or 76 not in mfg_dict:
            return
        raw = bytes(mfg_dict[76])
        decoded = decode_continuity_07(raw)
        if not decoded:
            return
        dev_mac = resolve_mac(path, addr_hint)
        if not dev_mac:
            return
        emit(decoded, dev_mac)

    class Monitor(dbus.service.Object):
        @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
        def GetAll(self, _iface):
            return {
                "Type": "or_patterns",
                "Patterns": dbus.Array(
                    [
                        dbus.Struct(
                            (dbus.Byte(0), dbus.Byte(0xFF), dbus.Array([dbus.Byte(0x4C), dbus.Byte(0x00), dbus.Byte(0x07)], signature="y")),
                            signature="yyay",
                        )
                    ],
                    signature="(yyay)",
                ),
            }

        @dbus.service.method("org.bluez.AdvertisementMonitor1", in_signature="", out_signature="")
        def Release(self):
            pass

        @dbus.service.method("org.bluez.AdvertisementMonitor1", in_signature="o", out_signature="")
        def DeviceFound(self, device):
            try:
                props = dbus.Interface(bus.get_object("org.bluez", device), "org.freedesktop.DBus.Properties")
                all_p = props.GetAll("org.bluez.Device1")
                handle_mfg_data(str(device), all_p.get("ManufacturerData"), str(all_p.get("Address", "")))
            except Exception:
                pass

        @dbus.service.method("org.bluez.AdvertisementMonitor1", in_signature="o", out_signature="")
        def DeviceLost(self, _device):
            pass

    class ObjectMgr(dbus.service.Object):
        @dbus.service.method("org.freedesktop.DBus.ObjectManager", in_signature="", out_signature="a{oa{sa{sv}}}")
        def GetManagedObjects(self):
            return {
                dbus.ObjectPath(MON_PATH): {
                    "org.bluez.AdvertisementMonitor1": {
                        "Type": "or_patterns",
                        "Patterns": dbus.Array(
                            [
                                dbus.Struct(
                                    (dbus.Byte(0), dbus.Byte(0xFF), dbus.Array([dbus.Byte(0x4C), dbus.Byte(0x00), dbus.Byte(0x07)], signature="y")),
                                    signature="yyay",
                                )
                            ],
                            signature="(yyay)",
                        ),
                    }
                }
            }

    def on_props_changed(iface, changed, _invalidated, path=None):
        if iface == "org.bluez.Device1" and path and "ManufacturerData" in changed:
            handle_mfg_data(str(path), changed["ManufacturerData"])

    def on_ifaces_added(path, ifaces):
        dev = ifaces.get("org.bluez.Device1")
        if dev and "ManufacturerData" in dev:
            handle_mfg_data(str(path), dev["ManufacturerData"], str(dev.get("Address", "")))

    bus.add_signal_receiver(
        on_props_changed,
        dbus_interface="org.freedesktop.DBus.Properties",
        signal_name="PropertiesChanged",
        arg0="org.bluez.Device1",
        path_keyword="path",
    )
    bus.add_signal_receiver(
        on_ifaces_added,
        dbus_interface="org.freedesktop.DBus.ObjectManager",
        signal_name="InterfacesAdded",
    )

    _om = ObjectMgr(bus, MON_BASE)
    _mon = Monitor(bus, MON_PATH)
    mgr_ref = [None]

    def start_monitor():
        try:
            om_bluez = dbus.Interface(bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager")
            for obj_path, ifaces in om_bluez.GetManagedObjects().items():
                dev = ifaces.get("org.bluez.Device1")
                if dev and "ManufacturerData" in dev:
                    handle_mfg_data(str(obj_path), dev["ManufacturerData"], str(dev.get("Address", "")))
        except Exception as e:
            sys.stderr.write(f"[podble] scan init: {e}\n")
        try:
            m = dbus.Interface(bus.get_object("org.bluez", "/org/bluez/hci0"), "org.bluez.AdvertisementMonitorManager1")
            mgr_ref[0] = m
            m.RegisterMonitor(
                dbus.ObjectPath(MON_BASE),
                reply_handler=lambda: None,
                error_handler=lambda e: sys.stderr.write(f"[podble] RegisterMonitor: {e}\n"),
            )
        except Exception as e:
            sys.stderr.write(f"[podble] RegisterMonitor init: {e}\n")
        return False

    GLib.idle_add(start_monitor)

    def shutdown(*_args):
        if mgr_ref[0] is not None:
            try:
                mgr_ref[0].UnregisterMonitor(
                    dbus.ObjectPath(MON_BASE),
                    reply_handler=lambda: loop.quit(),
                    error_handler=lambda _e: loop.quit(),
                )
                GLib.timeout_add(300, loop.quit)
                return True
            except Exception:
                pass
        loop.quit()
        return False

    sig_add = GLibUnix.signal_add if GLibUnix is not None else GLib.unix_signal_add
    sig_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, shutdown)
    sig_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, shutdown)
    loop.run()


if __name__ == "__main__":
    main()
