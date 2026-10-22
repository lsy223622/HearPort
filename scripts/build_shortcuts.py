"""Generate non-personal foreground Shortcuts sources and optionally sign on macOS.

Native background/audio actions are provided by AppShortcutsProvider in the app;
the URL variants deliberately exercise foreground launch separately.
"""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path

URL_COMMANDS = {
    "HearPort - Connect automatically": "hearport://connect",
    "HearPort - Network only": "hearport://connect?route=network",
    "HearPort - USB only": "hearport://connect?route=usb",
    "HearPort - Disconnect": "hearport://disconnect",
    "HearPort - Connection details": "hearport://status",
}


def shortcut(url):
    return {
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowClientVersion": "2600.0.3",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 61440},
        "WFWorkflowTypes": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowActions": [
            {"WFWorkflowActionIdentifier": "is.workflow.actions.url",
             "WFWorkflowActionParameters": {"WFURLActionURL": url}},
            {"WFWorkflowActionIdentifier": "is.workflow.actions.openurl",
             "WFWorkflowActionParameters": {}},
        ],
    }


def build(directory, sign=False):
    directory.mkdir(parents=True, exist_ok=True)
    sources = directory / "sources"
    sources.mkdir(exist_ok=True)
    results = []
    for name, url in URL_COMMANDS.items():
        source = sources / (name + ".shortcut")
        source.write_bytes(plistlib.dumps(shortcut(url), fmt=plistlib.FMT_BINARY))
        item = {"name": name, "url": url, "signed": False}
        if sign:
            try:
                result = subprocess.run(
                    ["/usr/bin/shortcuts", "sign", "--mode", "anyone", "--input", str(source),
                     "--output", str(directory / source.name)], capture_output=True, text=True, timeout=45)
                item["signed"] = result.returncode == 0 and (directory / source.name).is_file()
                item["sign_output"] = (result.stdout + result.stderr).strip()
            except (OSError, subprocess.TimeoutExpired) as error:
                item["sign_output"] = str(error)
        results.append(item)
    (directory / "signing-results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sign", action="store_true")
    args = parser.parse_args()
    build(args.output, args.sign)
