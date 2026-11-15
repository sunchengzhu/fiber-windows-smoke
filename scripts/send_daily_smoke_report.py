#!/usr/bin/env python3
"""Reuse workflow outputs to render and send the Fiber Windows daily report."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping
from datetime import datetime, timedelta, timezone
from typing import Any


DEFAULT_CHANNEL_ID = "1549402632203018410"
SUCCESS_COLOR = 0x2ECC71
FAILURE_COLOR = 0xE74C3C
OTHER_COLOR = 0xF1C40F
EMBED_TOTAL_LIMIT = 6000
FIELD_VALUE_LIMIT = 1024
SCENARIOS = (
    ("invoice", "Invoice · B → A"),
    ("keysend", "Keysend · A → CkbaNode-1"),
    ("routed", "Routed · B → A → CkbaNode-1"),
)
OUTCOMES = {
    "success": ("✅", "Passed"),
    "failure": ("❌", "Failed"),
    "cancelled": ("🛑", "Cancelled"),
    "skipped": ("⏭️", "Skipped"),
}


def _mapping(value: Any) -> Mapping[str, Any]:
    return value if isinstance(value, Mapping) else {}


def _one_line(value: Any, default: str = "unavailable") -> str:
    if value is None:
        return default
    return " ".join(str(value).replace("`", "'").split()) or default


def _length(value: str) -> int:
    # Counting UTF-16 units also stays safe for clients counting emoji as pairs.
    return len(value.encode("utf-16-le", errors="replace")) // 2


def _truncate(value: str, limit: int) -> str:
    if _length(value) <= limit:
        return value
    if limit <= 0:
        return ""
    used = 0
    result = []
    for char in value:
        size = _length(char)
        if used + size > limit - 1:
            break
        result.append(char)
        used += size
    return "".join(result).rstrip() + "…"


def _outcome(value: Any) -> tuple[str, str]:
    return OUTCOMES.get(_one_line(value).lower(), ("❔", "Unknown"))


def _duration(value: Any) -> str:
    try:
        seconds = float(value)
    except (TypeError, ValueError, OverflowError):
        return "duration unavailable"
    if not math.isfinite(seconds) or seconds < 0:
        return "duration unavailable"
    hours, remainder = divmod(round(seconds), 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours}h {minutes}m {secs}s"
    if minutes:
        return f"{minutes}m {secs}s"
    return f"{seconds:.1f}s" if seconds < 10 and not seconds.is_integer() else f"{secs}s"


def _parse_object(raw: Any) -> tuple[Mapping[str, Any], bool]:
    if not isinstance(raw, str) or not raw.strip():
        return {}, False
    try:
        value = json.loads(raw)
    except (ValueError, TypeError, RecursionError):
        return {}, True
    return (value, False) if isinstance(value, Mapping) else ({}, True)


def _step(steps: Mapping[str, Any], key: str) -> Mapping[str, Any]:
    return _mapping(steps.get(key))


def _output(steps: Mapping[str, Any], key: str, name: str) -> Any:
    return _mapping(_step(steps, key).get("outputs")).get(name)


def collect_report(environ: Mapping[str, str] | None = None) -> dict[str, Any]:
    """Read only explicit workflow outputs and GitHub context, never node RPCs."""
    env = os.environ if environ is None else environ
    steps, steps_invalid = _parse_object(env.get("FIBER_REPORT_STEPS_JSON"))
    is_daily = env.get("FIBER_REPORT_IS_DAILY") == "true" or env.get("GITHUB_EVENT_NAME") == "schedule"
    payment_ids = ("payment_scheduled", "payment_manual")
    selected = next((key for key in payment_ids if _output(steps, key, "report")), None)
    if selected is None:
        selected = next(
            (key for key in payment_ids if _step(steps, key).get("outcome") not in {None, "skipped"}),
            "payment_scheduled" if is_daily else "payment_manual",
        )
    payment, payment_invalid = _parse_object(_output(steps, selected, "report"))
    versions, versions_invalid = _parse_object(_output(steps, "versions", "report"))
    server = env.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    repository = env.get("GITHUB_REPOSITORY", "")
    run_id = env.get("GITHUB_RUN_ID", "")
    return {
        "job_result": env.get("FIBER_REPORT_JOB_RESULT", "unknown"),
        "steps": steps,
        "steps_invalid": steps_invalid,
        "payment": payment,
        "payment_invalid": payment_invalid,
        "payment_outcome": _step(steps, selected).get("outcome", "unknown"),
        "started_at": _output(steps, "initialize_report", "started_at"),
        "duration_seconds": _output(steps, "timing", "duration_seconds"),
        "versions": versions,
        "versions_invalid": versions_invalid,
        "run_url": f"{server}/{repository}/actions/runs/{run_id}" if repository and run_id else "",
        "run_number": env.get("GITHUB_RUN_NUMBER", "unknown"),
        "run_attempt": env.get("GITHUB_RUN_ATTEMPT", "1"),
        "branch": env.get("GITHUB_REF_NAME", "unknown"),
        "sha": env.get("GITHUB_SHA", "unknown"),
        "trigger": env.get("GITHUB_EVENT_NAME", "unknown"),
        "is_daily": is_daily,
        "gate_outcome": env.get("FIBER_REPORT_GATE_OUTCOME"),
    }


def _time_summary(report: Mapping[str, Any]) -> str:
    trigger = {"schedule": "Scheduled run", "workflow_dispatch": "Manual run"}.get(
        report.get("trigger"), _truncate(_one_line(report.get("trigger")), 80)
    )
    if report.get("is_daily"):
        trigger = "Scheduled run"
    try:
        started = datetime.fromisoformat(str(report.get("started_at", "")).replace("Z", "+00:00"))
        if started.tzinfo is None:
            raise ValueError("Timezone required")
        started = started.astimezone(timezone(timedelta(hours=8)))
        actual = f"{started:%Y-%m-%d %H:%M:%S} CST"
    except (ValueError, TypeError, OverflowError):
        actual = "unavailable"
    return f"{trigger} · Started {actual}"


def _version_summary(report: Mapping[str, Any]) -> str:
    versions = _mapping(report.get("versions"))
    expected, latest = (_mapping(versions.get(key)) for key in ("expected", "latest"))
    nodes = versions.get("nodes")
    nodes = {node.get("name"): node for node in nodes if isinstance(node, Mapping) and isinstance(node.get("name"), str) and node.get("name") in {"A", "B"}} if isinstance(nodes, list) else {}
    tag = expected.get("tag")
    a, b = (nodes.get(name, {}) for name in ("A", "B"))
    same_verified_versions = (
        versions.get("status") == "match" and not report.get("versions_invalid")
        and isinstance(tag, str) and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag)
        and all(isinstance(a.get(key), str) and a[key] and a[key] == b.get(key)
                for key in ("fnn_version", "cli_version", "rpc_version", "rpc_commit"))
        and a["fnn_version"].startswith(f"fnn Fiber {tag} (")
        and a["cli_version"] == f"fnn-cli {tag[1:]}" and a["rpc_version"] == tag[1:]
    )
    if same_verified_versions:
        installed = f"A/B `{_truncate(tag, 50)}`"
        if latest.get("status") != "ok" or versions.get("freshness") == "unknown":
            return f"{installed} · verified · latest stable unknown"
        if versions.get("freshness") == "current" and latest.get("tag") == tag:
            return f"{installed} · verified · latest stable"
        if versions.get("freshness") == "update_available":
            return f"{installed} · latest `{_truncate(_one_line(latest.get('tag')), 50)}` (manual upgrade)"
    # Expand the comparison when evidence is missing or a component differs.
    # Complete binary/RPC versions and commits also remain in GitHub Summary.
    lines = [f"CI expected `{_truncate(_one_line(expected.get('tag')), 50)}` · `{_one_line(expected.get('commit'))[:12]}`"]
    for name in ("A", "B"):
        node = nodes.get(name, {})
        lines.append(f"{name} FNN `{_truncate(_one_line(node.get('fnn_version')), 100)}` · CLI `{_truncate(_one_line(node.get('cli_version')), 60)}`")
        lines.append(f"{name} RPC `{_truncate(_one_line(node.get('rpc_version')), 50)}` · `{_truncate(_one_line(node.get('rpc_commit')), 60)}`")
    lines.append(f"Latest stable `{_truncate(_one_line(latest.get('tag')), 50)}`")
    if latest.get("status") != "ok":
        lines[-1] += " · lookup failed; freshness unknown"
    if report.get("versions_invalid"):
        lines.append("Version report JSON is invalid.")
    return "\n".join(lines)


def _version_alert(report: Mapping[str, Any]) -> tuple[str, str]:
    versions = _mapping(report.get("versions"))
    if versions.get("status") == "mismatch":
        errors = versions.get("errors")
        detail = "; ".join(_one_line(value) for value in errors[:6]) if isinstance(errors, list) else ""
        for code, label in (("cli_mismatch", "CLI version mismatch"), ("fnn_mismatch", "FNN version/commit mismatch"), ("rpc_mismatch", "running RPC version/commit mismatch")):
            detail = detail.replace(code, label)
        return "Fiber version mismatch", "❌ Fiber version mismatch: " + _truncate(detail, 300) + ". Align the nodes, CLI, and CI baseline."
    if versions.get("status") == "unavailable" or report.get("versions_invalid"):
        return "Fiber version check failed", "❌ Fiber version check failed. See Versions for installed versions and missing data."
    if versions.get("freshness") == "update_available":
        latest = _mapping(versions.get("latest"))
        return "New stable release", f"⚠️ Stable {_truncate(_one_line(latest.get('tag')), 50)} is available; tested baseline {_truncate(_one_line(_mapping(versions.get('expected')).get('tag')), 50)}. Upgrade manually."
    if versions and versions.get("freshness") == "unknown":
        return "Latest stable unknown", "⚠️ Latest stable lookup failed; testing the installed version."
    return "", ""


def _preflight_summary(report: Mapping[str, Any]) -> str:
    steps = _mapping(report.get("steps"))
    checks = [
        ("checkout", "Checkout"), ("initialize_report", "Report setup"),
        ("syntax", "PowerShell syntax"), ("unit", "PowerShell tests"),
        ("versions", "Installed Fiber versions"),
        ("timing", "Report timing"),
    ]
    if report.get("gate_outcome") is not None:
        checks.insert(0, ("daily_gate", "Daily execution gate"))
        steps = {**steps, "daily_gate": {"outcome": report["gate_outcome"]}}
    if "reconnect" in steps:
        checks.append(("reconnect", "Payment peer connection"))
    checks.append(("topology", "Topology"))
    if all(_step(steps, key).get("outcome") == "success" for key, _ in checks):
        return "✅ Preflight passed"
    result = "\n".join(f"{_outcome(_step(steps, key).get('outcome'))[0]} {label}"
                       for key, label in checks if _step(steps, key).get("outcome") != "success")
    if report.get("steps_invalid"):
        result += "\nWorkflow step details unavailable (invalid JSON)."
    return result


def _scenario_summary(name: str, scenario: Mapping[str, Any]) -> str:
    amount = _truncate(_one_line(scenario.get("amount_ckb")), 64)
    fee = _truncate(_one_line(scenario.get("fee_ckb")), 64)
    return f"{name} · **{amount} CKB** · fee {fee} CKB"


def build_discord_payload(report: Mapping[str, Any]) -> dict[str, Any]:
    """Render one bounded Discord embed without network side effects."""
    result = report.get("job_result")
    emoji, _ = _outcome(result)
    version_label, version_alert = _version_alert(report)
    if result == "success" and version_alert:
        emoji = "⚠️"
    branch = _truncate(_one_line(report.get("branch")), 100)
    sha = _one_line(report.get("sha"))[:7]
    ref = f"Branch `{branch}` · `{sha}`" if report.get("branch") != "main" else ""
    attempt = _one_line(report.get("run_attempt"), "1")
    if attempt != "1":
        ref += (" · " if ref else "") + f"retry `{_truncate(attempt, 30)}`"
    checks = {"name": "Checks", "value": _truncate(_preflight_summary(report), FIELD_VALUE_LIMIT), "inline": False}
    fields = [
        {"name": "Versions", "value": _truncate(_version_summary(report), FIELD_VALUE_LIMIT), "inline": False},
        checks,
    ]
    payment = _mapping(report.get("payment"))
    if payment.get("status") == "disabled":
        description = "Payment flow disabled; no payments sent."
        fields.append({"name": "⏭️ Payment flow", "value": _truncate(_one_line(payment.get("reason")), FIELD_VALUE_LIMIT), "inline": False})
    elif payment.get("status") == "success":
        raw_scenarios = payment.get("scenarios")
        scenarios = {
            scenario.get("key"): scenario for scenario in raw_scenarios
            if isinstance(scenario, Mapping) and isinstance(scenario.get("key"), str)
            and scenario.get("key") in {key for key, _ in SCENARIOS}
        } if isinstance(raw_scenarios, list) else {}
        description = f"{len(scenarios)}/3 payment scenarios have verified success summaries."
        if len(scenarios) == 3:
            description = "3/3 payment scenarios passed."
            checks["value"] += " · Balances & fees verified"
        payment_lines = []
        for key, name in SCENARIOS:
            scenario = scenarios.get(key)
            payment_lines.append(_scenario_summary(name, scenario) if scenario else f"❔ {name} · Summary unavailable")
        fields.append({"name": "Payments", "value": _truncate("\n".join(payment_lines), FIELD_VALUE_LIMIT), "inline": False})
    else:
        outcome = report.get("payment_outcome")
        if outcome in {"failure", "cancelled"}:
            description = f"Payment flow {_outcome(outcome)[1].lower()}; individual payment results unavailable."
            message = "No structured payment summary was produced; open the run log for details."
        elif outcome == "skipped":
            description = "Payment flow was skipped."
            message = "Payments were not requested, or an earlier step prevented the payment flow from starting."
            if _mapping(report.get("versions")).get("status") in {"mismatch", "unavailable"}:
                message = "Payments were not started: Fiber version checks failed. Compare installed versions with CI expected, then align the deployment and baseline."
        else:
            description = "Individual payment results unavailable."
            message = "No structured payment summary was produced; open the run log for details."
        if report.get("payment_invalid"):
            message += " The payment report JSON is invalid."
        fields.append({"name": f"{_outcome(outcome)[0]} Payment flow", "value": message, "inline": False})
    if result != "success":
        description += f" Workflow {_outcome(result)[1].lower()}."
    if version_alert:
        description = version_alert + "\n" + description
    description += f" · ⏱ {_duration(report.get('duration_seconds'))} · {_time_summary(report)}"
    if ref:
        description += "\n" + ref
    for field in fields:
        field["value"] = _truncate(field["value"], FIELD_VALUE_LIMIT)
    embed: dict[str, Any] = {
        "title": _truncate(f"{emoji} Fiber Windows Daily Smoke · {version_label or 'Testnet'} · #{_one_line(report.get('run_number'))}", 256),
        "description": _truncate(description, 4096),
        "color": FAILURE_COLOR if result == "failure" else OTHER_COLOR if version_alert or result != "success" else SUCCESS_COLOR,
        "fields": fields,
        "footer": {"text": "Click the title for the full report and logs"},
    }
    if report.get("run_url"):
        embed["url"] = _truncate(str(report["run_url"]), 2048)
    total = sum(_length(embed[key]) for key in ("title", "description")) + _length(embed["footer"]["text"])
    total += sum(_length(field["name"]) + _length(field["value"]) for field in fields)
    for field in reversed(fields):
        if total <= EMBED_TOTAL_LIMIT:
            break
        original = _length(field["value"])
        field["value"] = _truncate(field["value"], max(1, original - (total - EMBED_TOTAL_LIMIT)))
        total -= original - _length(field["value"])
    return {"allowed_mentions": {"parse": []}, "embeds": [embed]}


def payload_from_env(environ: Mapping[str, str] | None = None) -> dict[str, Any]:
    return build_discord_payload(collect_report(environ))


def _webhook_endpoint(webhook_url: str) -> str:
    # Only accept Discord token endpoints; query strings could redirect a post to a thread.
    try:
        parsed = urllib.parse.urlsplit(webhook_url)
        valid = (parsed.scheme == "https" and parsed.netloc in {"discord.com", "canary.discord.com", "ptb.discord.com", "discordapp.com"}
                 and re.fullmatch(r"/api/(?:v[0-9]+/)?webhooks/[0-9]+/[A-Za-z0-9_.-]+/?", parsed.path)
                 and not parsed.query and not parsed.fragment)
    except ValueError:
        valid = False
    if not valid:
        raise RuntimeError("DISCORD_WEBHOOK_URL must be a Discord webhook URL without query parameters.")
    return webhook_url.rstrip("/")


def _request_json(request: urllib.request.Request, timeout: int) -> Mapping[str, Any]:
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Discord webhook returned HTTP {exc.code}; check webhook access and configuration.") from None
    except (urllib.error.URLError, OSError, TimeoutError):
        raise RuntimeError("Discord webhook request failed; check network connectivity and try again.") from None
    except (ValueError, UnicodeError, RecursionError):
        raise RuntimeError("Discord webhook returned an invalid JSON response.") from None
    if not isinstance(data, Mapping):
        raise RuntimeError("Discord webhook returned an unexpected response.")
    return data


def send_discord_webhook(webhook_url: str, payload: Mapping[str, Any], expected_channel_id: str = DEFAULT_CHANNEL_ID, timeout: int = 20) -> None:
    """Verify the webhook channel, send once, then confirm the returned channel."""
    endpoint = _webhook_endpoint(webhook_url)
    if not re.fullmatch(r"[0-9]+", expected_channel_id):
        raise RuntimeError("DISCORD_CHANNEL_ID must be a numeric Discord channel ID.")
    headers = {"User-Agent": "fiber-windows-smoke/1.0", "Content-Type": "application/json"}
    webhook = _request_json(urllib.request.Request(endpoint, headers=headers, method="GET"), timeout)
    if str(webhook.get("channel_id", "")) != expected_channel_id:
        raise RuntimeError("Discord webhook channel does not match DISCORD_CHANNEL_ID; no message was sent.")
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    message = _request_json(urllib.request.Request(endpoint + "?wait=true", data=body, headers=headers, method="POST"), timeout)
    if str(message.get("channel_id", "")) != expected_channel_id:
        raise RuntimeError("Discord returned a different channel after sending; inspect the webhook configuration before retrying.")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Print the payload without credentials or network access")
    args = parser.parse_args(argv)
    payload = payload_from_env()
    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return
    webhook_url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not webhook_url:
        raise SystemExit("DISCORD_WEBHOOK_URL is required; configure it as a repository Actions secret.")
    channel_id = os.environ.get("DISCORD_CHANNEL_ID", DEFAULT_CHANNEL_ID).strip()
    try:
        send_discord_webhook(webhook_url, payload, channel_id)
    except RuntimeError as exc:
        raise SystemExit(str(exc)) from None
    print(f"Discord daily-smoke report sent to channel {channel_id}")


if __name__ == "__main__":
    main()
