"""Picks the iPhone or iPad that build.sh --app-phone and app/Probe/build.sh --phone install on.

    /usr/bin/python3 -I kiwix-mac/pick_device.py LISTING.json

LISTING.json is `xcrun devicectl list devices --json-output`. On success this prints one line, the device's UDID
(what xcodebuild and devicectl want), a tab, then "Name (Model)", and exits 0. Otherwise it prints one plain sentence
or two to stderr, for the owner, and exits 1. It never picks a device that isn't on the cable: an install goes to the
device the owner is looking at, or to none (2026-10-16: a plugged-in iPad that wasn't ready for development was skipped,
and the app went to an iPhone reached over Wi-Fi, which the script then called "the plugged-in iPhone").

A device on the cable whose connection is asleep is listed with no developerModeStatus, as if Developer Mode were off
(the iPhone and the iPad, 2026-10-28, both with it on). So when the one plugged-in device lacks it, this asks the device
for its details once (`xcrun devicectl device info details`, which wakes the connection), lists again, and decides on
that listing.

Standard library only, and Python 3.9 (macOS's own /usr/bin/python3): no `match`, no `X | Y` types.
"""

import json
import os
import subprocess
import sys
import tempfile

PLUG_IN = "Plug the iPhone or iPad to install on into this Mac with a cable, unlock it, and run this again."
NOT_READY = ("{name} is plugged in but not ready to install on. On it, open Settings › Privacy & Security › "
             "Developer Mode, turn it on, and restart it when it asks. If Developer Mode isn't listed, open Xcode on "
             "this Mac, choose Window › Devices and Simulators with it plugged in and unlocked, then look again. "
             "Then run this again.")


def merged(device, new, old):
    """One section of a device: devicectl's `properties` dictionary (the non-deprecated one, as the old inline
    snippets read it), with the deprecated top-level section filling whatever it lacks."""
    section = dict(device.get(old) or {})
    newer = (device.get("properties") or {}).get(new) or {}
    section.update({key: value for key, value in newer.items() if value is not None})
    return section


def clean(text):
    """A device's name is typed by its owner: keep control characters out of the one line this prints."""
    return "".join(" " if ord(char) < 32 or ord(char) == 127 else char for char in str(text)).strip()


def mode_of(status):
    """developerModeStatus is "enabled" in the old section and {"enabled": {...}} in `properties`."""
    if isinstance(status, dict):
        return next(iter(status), None)
    return status


class Device:
    def __init__(self, device):
        hardware = merged(device, "hardware", "hardwareProperties")
        link = merged(device, "connection", "connectionProperties")
        state = merged(device, "state", "deviceProperties")
        self.udid = hardware.get("udid")
        self.platform = hardware.get("platform")
        self.reality = hardware.get("reality")
        self.paired = link.get("pairingState") == "paired"
        self.transport = link.get("transportType")
        self.name = clean(state.get("name") or "")
        self.model = clean(hardware.get("marketingName") or hardware.get("productType")
                           or hardware.get("deviceType") or "")
        self.developer_mode = mode_of(state.get("developerModeStatus"))

    def real(self):
        """Not a simulator (those are listed too, shown connected) and not this Mac."""
        return bool(self.udid) and self.platform == "iOS" and self.paired and self.reality != "simulated" \
            and self.transport != "sameMachine"

    def ready(self):
        return self.reality == "physical" and self.developer_mode == "enabled"

    def label(self):
        if self.name and self.model:
            return "%s (%s)" % (self.name, self.model)
        return self.name or self.model or "an unnamed device"


def devices_in(path):
    try:
        with open(path, "rb") as listing:
            found = json.load(listing)["result"]["devices"]
        devices = []
        for entry in found:
            try:
                devices.append(Device(entry))
            except (TypeError, AttributeError):   # one odd entry doesn't hide the others
                continue
        return devices
    except (OSError, ValueError, KeyError, TypeError):
        return []


def names(devices):
    return ", ".join(device.name or device.model or "an unnamed device" for device in devices)


def choose(devices):
    """(the chosen Device, None) or (None, the message to show the owner)."""
    real = [device for device in devices if device.real()]
    plugged = [device for device in real if device.transport == "wired"]
    on_wifi = [device for device in real if device.transport != "wired"]
    if not plugged:
        message = PLUG_IN
        if on_wifi:
            one = len(on_wifi) == 1
            message += "\n%s %s seen over Wi-Fi. %s used, because %s on the cable." % (
                names(on_wifi), "was" if one else "were", "It isn't" if one else "They aren't",
                "it isn't" if one else "they aren't")
        return None, message
    if len(plugged) > 1:
        return None, "Plug in only one iPhone or iPad at a time (plugged in now: %s)." % names(plugged)
    if not plugged[0].ready():
        return None, NOT_READY.format(name=plugged[0].name or "The plugged-in device")
    return plugged[0], None


def woken(udid):
    """The devices listed again after waking this one's connection, or [] if devicectl couldn't."""
    quiet = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL, "timeout": 60}
    try:
        subprocess.run(["xcrun", "devicectl", "device", "info", "details", "--device", udid], **quiet)
        with tempfile.TemporaryDirectory() as folder:
            again = os.path.join(folder, "devices.json")
            subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", again], **quiet)
            return devices_in(again)
    except (OSError, subprocess.SubprocessError):
        return []


def write(stream, text):
    stream.buffer.write((text + "\n").encode("utf-8"))   # UTF-8 whatever the locale: the messages hold "›"
    stream.flush()


def main(argv):
    if len(argv) != 2:
        write(sys.stderr, "usage: pick_device.py LISTING.json")
        return 2
    devices = devices_in(argv[1])
    plugged = [device for device in devices if device.real() and device.transport == "wired"]
    if len(plugged) == 1 and plugged[0].developer_mode is None:
        devices = woken(plugged[0].udid) or devices
    chosen, message = choose(devices)
    if chosen is None:
        write(sys.stderr, message)
        return 1
    write(sys.stdout, "%s\t%s" % (chosen.udid, chosen.label()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
