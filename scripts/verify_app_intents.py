"""Check the actual archive metadata, not just source declarations."""
import argparse
import json
import plistlib
from pathlib import Path


def verify(app):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert any("hearport" in item.get("CFBundleURLSchemes", []) for item in info.get("CFBundleURLTypes", []))
    assert "audio" in info.get("UIBackgroundModes", [])
    metadata = json.loads((app / "Metadata.appintents" / "extract.actionsdata").read_text(encoding="utf-8"))
    actions = metadata["actions"]
    expected = {"PlayPCAudioIntent", "BackgroundConnectIntent", "OpenAndConnectIntent",
                "DisconnectPCAudioIntent", "ConnectionStatusIntent", "AutomationMarkerIntent",
                "PlayNetworkAudioIntent", "PlayUSBAudioIntent", "BackgroundNetworkIntent", "BackgroundUSBIntent"}
    assert expected <= actions.keys(), "Missing App Intent metadata"
    for name in expected:
        assert actions[name]["isDiscoverable"], name
        assert actions[name]["openAppWhenRun"] == (name == "OpenAndConnectIntent"), name
    for name in ["PlayPCAudioIntent", "DisconnectPCAudioIntent", "PlayNetworkAudioIntent", "PlayUSBAudioIntent"]:
        assert "com.apple.link.systemProtocol.AudioStarting" in actions[name]["systemProtocols"], name
    for name in ["PlayPCAudioIntent", "BackgroundConnectIntent", "OpenAndConnectIntent"]:
        assert any(p["name"] == "route" for p in actions[name]["parameters"]), name
    assert {s["actionIdentifier"] for s in metadata["autoShortcuts"]} == expected, "Missing distinct shortcut entry points"
    routes = next(item for item in metadata["enums"] if item["identifier"] == "HearPortRoute")
    assert {item["identifier"] for item in routes["cases"]} == {"automatic", "network", "usb"}
    print("Verified 10 intents, 10 App Shortcuts, 3 routes and foreground/audio execution metadata")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    verify(parser.parse_args().app)
