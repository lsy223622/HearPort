"""Compare network probe loss stages and virtual receive-buffer behavior."""

import argparse
import json
from collections import Counter
from pathlib import Path


def load_report(path):
    rounds = []
    arrivals = []
    section = None
    stream_id = None
    with path.open(encoding="utf-8") as source:
        for raw in source:
            line = raw.rstrip("\n")
            if line.startswith("stream_id="):
                stream_id = int(line.partition("=")[2])
            elif line in ("network_probe_rounds_v1", "network_probe_rounds_v2"):
                section = "rounds"
                header = None
            elif line == "network_probe_trace_v1":
                section = "trace"
                header = None
            elif line == "app_diagnostics_v1":
                break
            elif section and line:
                if header is None:
                    header = line.split("\t")
                    continue
                values = dict(zip(header, line.split("\t")))
                if section == "rounds":
                    rounds.append({key: int(value) if value.isdecimal() else value
                                   for key, value in values.items()})
                else:
                    arrivals.append((int(values["received_at_ns"]),
                                     int(values["sequence"])))
    if not rounds:
        raise ValueError("report contains no network probe rounds")
    return stream_id, rounds, arrivals


def load_sender(path):
    packets = {}
    with path.open(encoding="utf-8") as source:
        for line in source:
            record = json.loads(line)
            if record.get("type") == "packet":
                packets[record["sequence"]] = record
    return packets


def load_sender_rounds(path, stream_id):
    summaries = {}
    if path is None:
        return summaries
    with path.open(encoding="utf-8", errors="replace") as source:
        for line in source:
            marker = "network_probe_round_end "
            if marker not in line:
                continue
            fields = dict(field.split("=", 1) for field in
                          line.split(marker, 1)[1].split() if "=" in field)
            if fields.get("stream_id") == str(stream_id):
                summaries[int(fields["round"])] = {
                    key: int(value) for key, value in fields.items()
                    if value.isdecimal() and key not in ("round", "stream_id")
                }
    return summaries


def simulate_buffer(arrivals_ns, rate, seconds, target_ms, adaptive):
    if not arrivals_ns:
        return None
    arrivals = sorted(arrivals_ns)
    first = arrivals[0]
    end = first + seconds * 1_000_000_000
    now = first + target_ms * 1_000_000
    interval = 1_000_000_000 / rate
    target_packets = rate * target_ms / 1_000
    index = 0
    fill = 0
    ticks = empty = episodes = peak = slow = fast = 0
    was_empty = False
    while now < end:
        while index < len(arrivals) and arrivals[index] <= now:
            index += 1
            fill += 1
        peak = max(peak, fill)
        if adaptive and fill < target_packets * 0.5:
            speed = 0.98
            slow += 1
        elif adaptive and fill > target_packets * 1.5:
            speed = 1.02
            fast += 1
        else:
            speed = 1.0
        if fill:
            fill -= 1
            was_empty = False
        else:
            empty += 1
            if not was_empty:
                episodes += 1
            was_empty = True
        ticks += 1
        now += interval / speed
    return {"ticks": ticks, "empty": empty, "episodes": episodes,
            "end_fill": fill, "peak_fill": peak, "slow_ticks": slow,
            "fast_ticks": fast}


def analyze(report, sender, target_ms, sender_log=None):
    stream_id, rounds, arrivals = load_report(report)
    packets = load_sender(sender)
    sender_rounds = load_sender_rounds(sender_log, stream_id)
    for round_info in rounds:
        start = round_info["first_sequence"]
        stop = start + round_info["planned"]
        first_arrival = {}
        for time, sequence in arrivals:
            if start <= sequence < stop:
                first_arrival[sequence] = min(time, first_arrival.get(sequence, time))
        received = set(first_arrival)
        times = sorted(first_arrival.values())
        sender_rows = {sequence: packets[sequence] for sequence in range(start, stop)
                       if sequence in packets}
        missing = set(range(start, stop)) - received
        rejected = sum(not row["send_accepted"] for row in sender_rows.values())
        rejected_missing = sum(not sender_rows[sequence]["send_accepted"]
                               for sequence in missing if sequence in sender_rows)
        states = Counter(sender_rows[sequence]["send_state"] for sequence in missing
                         if sequence in sender_rows and sender_rows[sequence]["send_accepted"])
        gaps_ms = [(b - a) / 1_000_000 for a, b in zip(times, times[1:])]
        fixed = simulate_buffer(times, round_info["packets_per_second"],
                                round_info["seconds"], target_ms, False)
        adaptive = simulate_buffer(times, round_info["packets_per_second"],
                                   round_info["seconds"], target_ms, True)
        yield {
            "round": round_info["round"], "transport": round_info["transport"],
            "repeat": round_info.get("repeat"),
            "variant": round_info.get("variant"),
            "payload_bytes": round_info["payload_bytes"],
            "packets_per_second": round_info["packets_per_second"],
            "burst_packets": round_info["burst_packets"],
            "planned": round_info["planned"], "received_unique": len(received),
            "sender_trace_missing": round_info["planned"] - len(sender_rows),
            "sender_rejected": rejected,
            "missing_after_sender_rejection": rejected_missing,
            "missing_after_accepted_by_send_state": dict(states),
            "max_receiver_gap_ms": round(max(gaps_ms), 2) if gaps_ms else None,
            "receiver_gaps_over_100_ms": sum(gap > 100 for gap in gaps_ms),
            "sender_round": sender_rounds.get(round_info["round"]),
            "fixed_buffer": fixed, "adaptive_buffer": adaptive,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("sender_trace", type=Path)
    parser.add_argument("--sender-log", type=Path,
                        help="optional HearPort-sender.log with send rejection reasons")
    parser.add_argument("--target-ms", type=int, default=100,
                        help="virtual startup and target buffer (default: 100 ms)")
    args = parser.parse_args()
    if args.target_ms <= 0:
        parser.error("--target-ms must be positive")
    for result in analyze(args.report, args.sender_trace, args.target_ms,
                          args.sender_log):
        print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
