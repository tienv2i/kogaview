#!/usr/bin/env python3
"""Probe the XDG portal the way KogaView's `PlatformHelper` does.

Run it when a portal dialog misbehaves:
    python3 scripts/portal_probe.py        # needs PyGObject (`python-gobject`)

It prints the predicted request handle, the returned one, whether they match,
and any `Response` the portal emits. A mismatch or an endless silence is a
portal/backend problem, not a KogaView one.

The steps mirror the C++ client:
1. compute the request handle path from *our own* unique bus name + token,
2. subscribe to `Response` there **before** calling the method,
3. call FileChooser.OpenFile with `directory: true` (there is no OpenFolder),
4. close the request and print the response that arrives.
"""

import sys

from gi.repository import Gio, GLib

PORTAL = "org.freedesktop.portal.Desktop"
PATH = "/org/freedesktop/portal/desktop"
FILE_CHOOSER = "org.freedesktop.portal.FileChooser"
REQUEST = "org.freedesktop.portal.Request"

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
unique = bus.get_unique_name()  # e.g. ':1.42'
token = "kogaprobe_1"
handle = "%s/request/%s/%s" % (PATH, unique[1:].replace(".", "_"), token)
print("caller", unique)
print("predicted handle", handle)

loop = GLib.MainLoop()
state = {"responses": []}


def on_response(connection, sender, object_path, interface, signal, params):
    response, results = params.unpack()
    state["responses"].append((object_path, response, results))
    print("Response on", object_path, "code", response, "results", results)
    loop.quit()


bus.signal_subscribe(PORTAL, REQUEST, "Response", handle, None, 0, on_response)

options = {
    "handle_token": GLib.Variant("s", token),
    "multiple": GLib.Variant("b", False),
    "directory": GLib.Variant("b", True),
}
result = bus.call_sync(
    PORTAL,
    PATH,
    FILE_CHOOSER,
    "OpenFile",
    GLib.Variant("(ssa{sv})", ("", "KogaView probe", options)),
    GLib.VariantType("(o)"),
    Gio.DBusCallFlags.NONE,
    5000,
    None,
)
returned = result.unpack()[0]
print("returned handle", returned, "matches prediction:", returned == handle)

# Close it the way the timeout path does, then wait for the answer.
try:
    bus.call_sync(PORTAL, returned, REQUEST, "Close", None, None, Gio.DBusCallFlags.NONE, 5000, None)
    print("closed")
except GLib.GError as error:
    print("close failed (request already finished):", error.message)

GLib.timeout_add(4000, lambda: loop.quit())
loop.run()
print("responses seen:", len(state["responses"]))
sys.exit(0 if state["responses"] else 1)
