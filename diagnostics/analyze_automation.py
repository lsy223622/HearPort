"""Summarize exported local automation stages without inferring unobserved triggers."""
import argparse
import json
import re
from pathlib import Path


def summarize(text):
    requests = {}
    for line in text.splitlines():
        if " automation_stage | " not in line:
            continue
        fields = dict(re.findall(r"(?:^|\s)(\w+)=([^\s]+)", line.split(" | ", 1)[1]))
        request = fields.get("request_id")
        if not request:
            continue
        row = requests.setdefault(request, {"request_id": request, "stages_ms": {}})
        stage = fields.get("stage")
        for name in ["source", "requested_route", "pid", "build", "os"]:
            if name in fields:
                row[name] = fields[name]
        if stage == "action_entered":
            row["entry_app_state"] = fields.get("application_state")
            row["ui_appeared_at_entry"] = fields.get("ui_appeared")
        if stage and fields.get("elapsed_ms", "").isdigit():
            elapsed = int(fields["elapsed_ms"])
            row["stages_ms"][stage] = min(elapsed, row["stages_ms"].get(stage, elapsed))
        if stage == "action_returned":
            row["returned_result"] = fields.get("result")
    for row in requests.values():
        stages = row["stages_ms"]
        row["action_entered"] = "action_entered" in stages
        row["session_ready"] = "session_ready" in stages
        row["engine_started"] = "audio_engine_started" in stages
        row["received_audio_rendered"] = "received_audio_rendered" in stages
        row["audible_sound"] = "not_measured"
    return list(requests.values())


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.log.read_text(encoding="utf-8-sig", errors="replace")), indent=2))
