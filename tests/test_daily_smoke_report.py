"""Offline report and webhook contract checks; no payment or network side effects."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest import mock
import urllib.error


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "send_daily_smoke_report.py"
SPEC = importlib.util.spec_from_file_location("send_daily_smoke_report", SCRIPT)
report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report)
WEBHOOK = "https://discord.com/api/webhooks/123456/secret-token"


def success_payment():
    return {
        "status": "success",
        "scenarios": [
            {
                "key": key,
                "amount_ckb": amount,
                "fee_ckb": fee,
                "fee_shannons": shannons,
                "payment_hash": "0x" + str(index) * 64,
                "balances": [
                    {"label": "Node B" if key != "keysend" else "Node A", "before_ckb": "1", "after_ckb": "0.98"},
                    {"label": "Node A" if key == "invoice" else "CkbaNode-1", "before_ckb": "2", "after_ckb": "2.02"},
                ],
                "assertions": "Exact amount, zero fee, and balance conservation passed" if key != "routed" else "Positive fee, both hops, and balance conservation passed",
                **({"fee_rate_millionths": "1000"} if key == "routed" else {}),
            }
            for index, (key, amount, fee, shannons) in enumerate([
                ("invoice", "0.02", "0", "0"),
                ("keysend", "0.01", "0", "0"),
                ("routed", "0.03", "0.00003", "3000"),
            ], 1)
        ],
    }


def complete_steps():
    steps = {
        key: {"outcome": "success", "outputs": {}}
        for key in ("checkout", "initialize_report", "syntax", "unit", "update_a", "update_b", "topology", "payment_scheduled", "timing")
    }
    steps.update({key: {"outcome": "skipped", "outputs": {}} for key in ("ensure_a", "ensure_b", "topology_ensured", "payment_manual")})
    steps["initialize_report"]["outputs"]["started_at"] = "2026-09-15T00:02:03Z"
    steps["timing"]["outputs"]["duration_seconds"] = "125.2"
    steps["update_a"]["outputs"]["fnn_version"] = "fnn 0.9.1"
    steps["update_b"]["outputs"]["fnn_version"] = "fnn 0.9.1"
    steps["payment_scheduled"]["outputs"]["report"] = json.dumps(success_payment())
    return steps


def complete_env(steps=None):
    return {
        "FIBER_REPORT_JOB_RESULT": "success",
        "FIBER_REPORT_STEPS_JSON": json.dumps(complete_steps() if steps is None else steps),
        "GITHUB_SERVER_URL": "https://github.com",
        "GITHUB_REPOSITORY": "sunchengzhu/fiber-windows-smoke",
        "GITHUB_RUN_ID": "100",
        "GITHUB_RUN_NUMBER": "42",
        "GITHUB_RUN_ATTEMPT": "1",
        "GITHUB_REF_NAME": "main",
        "GITHUB_SHA": "0123456789abcdef",
        "GITHUB_EVENT_NAME": "schedule",
    }


def fields(payload):
    return {field["name"]: field["value"] for field in payload["embeds"][0]["fields"]}


def response(data):
    result = mock.MagicMock()
    result.__enter__.return_value.read.return_value = json.dumps(data).encode("utf-8")
    return result


class PayloadTests(unittest.TestCase):
    def test_success_reuses_all_payment_details(self):
        payload = report.payload_from_env(complete_env())
        embed = payload["embeds"][0]
        self.assertEqual(embed["color"], report.SUCCESS_COLOR)
        self.assertEqual(embed["description"], "3/3 payment scenarios passed.")
        self.assertEqual(embed["url"], "https://github.com/sunchengzhu/fiber-windows-smoke/actions/runs/100")
        rendered = fields(payload)
        self.assertIn("Branch `main` · `0123456`", rendered["Run overview"])
        self.assertIn("⏱ 2m 5s", rendered["Run overview"])
        self.assertIn("**All passed**", rendered["Preflight"])
        self.assertIn("Node A FNN `fnn 0.9.1`", rendered["Run overview"])
        for key, name in report.SCENARIOS:
            self.assertIn("**Payment hash:** `0x", rendered["✅ " + name])
            self.assertIn("1 → 0.98 CKB", rendered["✅ " + name])
        routed = rendered["✅ " + report.SCENARIOS[2][1]]
        self.assertIn("0.00003 CKB (3000 shannons)", routed)
        self.assertIn("1000 millionths", routed)
        self.assertEqual(payload["allowed_mentions"], {"parse": []})

    def test_schedule_and_actual_start_do_not_invent_delay_or_scheduled_date(self):
        overview = fields(report.payload_from_env(complete_env()))["Run overview"]
        self.assertIn("Schedule: daily 08:01 CST (UTC+8)", overview)
        self.assertIn("Actual start: 2026-09-15 08:02:03 CST", overview)
        self.assertNotIn("Delay", overview)
        self.assertNotIn("Scheduled 2026", overview)

    def test_manual_payment_and_ensure_steps(self):
        steps = complete_steps()
        steps["payment_manual"] = steps["payment_scheduled"]
        steps["payment_scheduled"] = {"outcome": "skipped"}
        steps["topology"]["outcome"] = "skipped"
        for key in ("ensure_a", "ensure_b", "topology_ensured"):
            steps[key]["outcome"] = "success"
        env = complete_env(steps)
        env.update({"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_RUN_ATTEMPT": "2"})
        rendered = fields(report.payload_from_env(env))
        self.assertIn("Trigger: workflow_dispatch", rendered["Run overview"])
        self.assertNotIn("Schedule:", rendered["Run overview"])
        self.assertIn("retry `2`", rendered["Run overview"])
        self.assertIn("**All passed**", rendered["Preflight"])
        self.assertIn("Node B channel", rendered["Preflight"])

    def test_failure_without_json_does_not_invent_payment_count(self):
        steps = complete_steps()
        steps["payment_scheduled"] = {"outcome": "failure", "outputs": {}}
        env = complete_env(steps)
        env["FIBER_REPORT_JOB_RESULT"] = "failure"
        payload = report.payload_from_env(env)
        text = json.dumps(payload)
        self.assertEqual(payload["embeds"][0]["color"], report.FAILURE_COLOR)
        self.assertIn("individual payment results unavailable", text)
        self.assertIn("No structured payment summary", text)
        self.assertNotIn("0/3", text)
        self.assertNotIn("3/3", text)
        self.assertNotIn("✅ Invoice", text)

    def test_bad_payment_json_has_safe_fallback(self):
        steps = complete_steps()
        steps["payment_scheduled"]["outputs"]["report"] = "{private-malformed-data"
        text = json.dumps(report.payload_from_env(complete_env(steps)))
        self.assertIn("payment report JSON is invalid", text)
        self.assertNotIn("private-malformed-data", text)
        self.assertNotIn("3/3", text)

    def test_disabled_is_not_three_passes(self):
        steps = complete_steps()
        steps["payment_scheduled"]["outputs"]["report"] = json.dumps({"status": "disabled", "reason": "Payment flow is disabled in settings; nothing sent"})
        text = json.dumps(report.payload_from_env(complete_env(steps)))
        self.assertIn("Payment flow disabled; no payments sent.", text)
        self.assertIn("disabled in settings", text)
        self.assertNotIn("3/3", text)

    def test_skipped_manual_payment_is_not_requested(self):
        steps = complete_steps()
        steps["payment_scheduled"] = {"outcome": "skipped"}
        env = complete_env(steps)
        env["GITHUB_EVENT_NAME"] = "workflow_dispatch"
        text = json.dumps(report.payload_from_env(env))
        self.assertIn("Payment flow was skipped", text)
        self.assertIn("Payments were not requested", text)
        self.assertNotIn("3/3", text)

    def test_preflight_failure_is_visible_when_payments_skipped(self):
        steps = complete_steps()
        steps["update_a"]["outcome"] = "failure"
        steps["payment_scheduled"] = {"outcome": "skipped"}
        env = complete_env(steps)
        env["FIBER_REPORT_JOB_RESULT"] = "failure"
        rendered = fields(report.payload_from_env(env))
        self.assertIn("❌ Node A update", rendered["Preflight"])
        self.assertNotIn("All passed", rendered["Preflight"])

    def test_missing_and_invalid_workflow_outputs_still_render(self):
        for raw in ("", "broken", "[]", "null"):
            with self.subTest(raw=raw):
                payload = report.payload_from_env({"FIBER_REPORT_STEPS_JSON": raw, "FIBER_REPORT_JOB_RESULT": "failure"})
                self.assertEqual(payload["embeds"][0]["color"], report.FAILURE_COLOR)
                self.assertNotIn("3/3", json.dumps(payload))

    def test_invalid_timing_is_not_fabricated(self):
        for started in (None, "invalid", "2026-09-15T00:00:00"):
            with self.subTest(started=started):
                steps = complete_steps()
                steps["initialize_report"]["outputs"]["started_at"] = started
                steps["timing"]["outputs"]["duration_seconds"] = "NaN"
                overview = fields(report.payload_from_env(complete_env(steps)))["Run overview"]
                self.assertIn("Actual start: unavailable", overview)
                self.assertIn("duration unavailable", overview)

    def test_missing_scenario_never_claims_three_passes(self):
        steps = complete_steps()
        payment = success_payment()
        payment["scenarios"].pop()
        payment["scenarios"].append({"key": ["bad-type"]})
        steps["payment_scheduled"]["outputs"]["report"] = json.dumps(payment)
        text = json.dumps(report.payload_from_env(complete_env(steps)))
        self.assertIn("2/3 payment scenarios have verified success summaries", text)
        self.assertNotIn("3/3", text)

    def test_long_untrusted_fields_obey_all_discord_limits(self):
        hostile = "😀@everyone`\n" * 2000
        steps = complete_steps()
        payment = success_payment()
        for scenario in payment["scenarios"]:
            for key in ("amount_ckb", "fee_ckb", "fee_shannons", "assertions", "payment_hash", "fee_rate_millionths"):
                scenario[key] = hostile
            scenario["balances"] = [{"label": hostile, "before_ckb": hostile, "after_ckb": hostile}] * 20
        steps["payment_scheduled"]["outputs"]["report"] = json.dumps(payment)
        steps["update_a"]["outputs"]["fnn_version"] = hostile
        steps["update_b"]["outputs"]["fnn_version"] = hostile
        env = complete_env(steps)
        for key in ("GITHUB_RUN_NUMBER", "GITHUB_REF_NAME", "GITHUB_RUN_ATTEMPT"):
            env[key] = hostile
        payload = report.payload_from_env(env)
        embed = payload["embeds"][0]
        self.assertLessEqual(report._length(embed["title"]), 256)
        self.assertLessEqual(report._length(embed["description"]), 4096)
        for field in embed["fields"]:
            self.assertLessEqual(report._length(field["name"]), 256)
            self.assertLessEqual(report._length(field["value"]), 1024)
        total = sum(report._length(embed[key]) for key in ("title", "description")) + report._length(embed["footer"]["text"])
        total += sum(report._length(field["name"]) + report._length(field["value"]) for field in embed["fields"])
        self.assertLessEqual(total, 6000)
        self.assertEqual(payload["allowed_mentions"], {"parse": []})

    def test_dry_run_needs_no_secret_and_makes_no_request(self):
        with mock.patch.dict(report.os.environ, complete_env(), clear=True), mock.patch.object(report.urllib.request, "urlopen") as request:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                report.main(["--dry-run"])
            self.assertEqual(json.loads(output.getvalue())["embeds"][0]["description"], "3/3 payment scenarios passed.")
            request.assert_not_called()

    def test_missing_secret_has_actionable_error(self):
        with mock.patch.dict(report.os.environ, {}, clear=True):
            with self.assertRaisesRegex(SystemExit, "configure it as a repository Actions secret"):
                report.main([])


class WebhookTests(unittest.TestCase):
    def test_checks_channel_before_post_and_requests_server_confirmation(self):
        payload = report.payload_from_env(complete_env())
        with mock.patch.object(report.urllib.request, "urlopen", side_effect=[response({"channel_id": report.DEFAULT_CHANNEL_ID}), response({"channel_id": report.DEFAULT_CHANNEL_ID, "id": "111"})]) as request:
            report.send_discord_webhook(WEBHOOK, payload)
        self.assertEqual(request.call_count, 2)
        first, second = (call.args[0] for call in request.call_args_list)
        self.assertEqual(first.get_method(), "GET")
        self.assertEqual(second.get_method(), "POST")
        self.assertEqual(second.full_url, WEBHOOK + "?wait=true")
        self.assertEqual(json.loads(second.data), payload)
        self.assertTrue(all(call.kwargs["timeout"] == 20 for call in request.call_args_list))

    def test_wrong_channel_never_posts(self):
        with mock.patch.object(report.urllib.request, "urlopen", return_value=response({"channel_id": "999"})) as request:
            with self.assertRaisesRegex(RuntimeError, "no message was sent"):
                report.send_discord_webhook(WEBHOOK, {})
        request.assert_called_once()
        self.assertEqual(request.call_args.args[0].get_method(), "GET")

    def test_wrong_post_channel_does_not_retry(self):
        with mock.patch.object(report.urllib.request, "urlopen", side_effect=[response({"channel_id": report.DEFAULT_CHANNEL_ID}), response({"channel_id": "999"})]) as request:
            with self.assertRaisesRegex(RuntimeError, "after sending"):
                report.send_discord_webhook(WEBHOOK, {})
        self.assertEqual(request.call_count, 2)

    def test_http_errors_never_expose_url_token_or_body(self):
        for status in (400, 401, 403, 404, 429, 500):
            with self.subTest(status=status):
                error = urllib.error.HTTPError(WEBHOOK, status, "secret-token", {}, io.BytesIO(b"private-response secret-token"))
                with mock.patch.object(report.urllib.request, "urlopen", side_effect=error):
                    with self.assertRaises(RuntimeError) as raised:
                        report.send_discord_webhook(WEBHOOK, {})
                self.assertIn(f"HTTP {status}", str(raised.exception))
                self.assertNotIn("secret-token", str(raised.exception))
                self.assertNotIn("private-response", str(raised.exception))
                self.assertNotIn(WEBHOOK, str(raised.exception))
                self.assertTrue(raised.exception.__suppress_context__)

    def test_network_error_never_exposes_url_or_reason(self):
        error = urllib.error.URLError("Failed secret-token at " + WEBHOOK)
        with mock.patch.object(report.urllib.request, "urlopen", side_effect=error):
            with self.assertRaises(RuntimeError) as raised:
                report.send_discord_webhook(WEBHOOK, {})
        self.assertIn("network connectivity", str(raised.exception))
        self.assertNotIn("secret-token", str(raised.exception))

    def test_invalid_response_is_redacted(self):
        invalid = mock.MagicMock()
        invalid.__enter__.return_value.read.return_value = b"secret-token private-response"
        with mock.patch.object(report.urllib.request, "urlopen", return_value=invalid):
            with self.assertRaisesRegex(RuntimeError, "invalid JSON response") as raised:
                report.send_discord_webhook(WEBHOOK, {})
        self.assertNotIn("secret-token", str(raised.exception))

    def test_discord_url_required_and_thread_query_rejected(self):
        for url in ("https://example.com/api/webhooks/1/secret-token", "http://discord.com/api/webhooks/1/secret-token", WEBHOOK + "?thread_id=999", WEBHOOK + "#secret-token"):
            with self.subTest(url=url), mock.patch.object(report.urllib.request, "urlopen") as request:
                with self.assertRaisesRegex(RuntimeError, "must be a Discord webhook URL") as raised:
                    report.send_discord_webhook(url, {})
                self.assertNotIn("secret-token", str(raised.exception))
                request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
