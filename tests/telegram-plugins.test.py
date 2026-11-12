#!/usr/bin/env python3
"""Tests for the Telegram button-plugin runner in telegram-bot.py.

No network, no Telegram: the `telegram` package is stubbed, plugins are tiny
shell scripts in a temp dir. Run: python3 tests/telegram-plugins.test.py
"""
import asyncio
import importlib.util
import os
import signal
import sys
import tempfile
import textwrap
import time
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _stub_telegram():
    class _F:
        def __and__(self, o): return self
        def __invert__(self): return self
    tg = types.ModuleType("telegram")
    for n in ("InlineKeyboardButton", "InlineKeyboardMarkup", "Update"):
        setattr(tg, n, type(n, (), {"__init__": lambda self, *a, **k: None}))
    err = types.ModuleType("telegram.error")
    for n in ("Conflict", "NetworkError", "TimedOut"):
        setattr(err, n, type(n, (Exception,), {}))
    ext = types.ModuleType("telegram.ext")
    ctxt = type("ContextTypes", (), {"DEFAULT_TYPE": object})
    ext.ContextTypes = ctxt
    ext.filters = types.SimpleNamespace(VOICE=_F(), TEXT=_F(), COMMAND=_F())
    for n in ("ApplicationBuilder", "CallbackQueryHandler", "CommandHandler", "MessageHandler"):
        setattr(ext, n, type(n, (), {}))
    sys.modules.update({"telegram": tg, "telegram.error": err, "telegram.ext": ext})


def load_bot():
    os.environ.setdefault("MEGAVIBE_TELEGRAM_TOKEN", "x")
    os.environ.setdefault("MEGAVIBE_TELEGRAM_USER_ID", "1")
    _stub_telegram()
    spec = importlib.util.spec_from_file_location("tgbot", ROOT / "telegram-bot.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bot = load_bot()


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # a zombie still answers kill(0); treat it as dead
    try:
        st = os.popen(f"ps -o stat= -p {pid}").read().strip()
    except Exception:
        return True
    return bool(st) and not st.startswith("Z")


def wait_dead(pid, secs=3.0):
    end = time.time() + secs
    while time.time() < end:
        if not alive(pid):
            return True
        time.sleep(0.05)
    return not alive(pid)


class Base(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def plugin(self, body, name="p"):
        p = self.dir / name
        p.write_text("#!/bin/sh\n" + textwrap.dedent(body))
        p.chmod(0o755)
        return p

    async def run_p(self, p, mode="callback", arg="x", limit=20, **kw):
        return await asyncio.wait_for(bot.run_plugin(p, mode, arg, {"a": 1}, **kw), limit)


class TestOutputCap(Base):  # F1
    async def test_stdout_flood_is_capped_and_group_killed(self):
        p = self.plugin("echo $$ > %s/pid\nexec yes\n" % self.dir)
        t0 = time.time()
        res = await self.run_p(p, limit=15)
        self.assertLess(time.time() - t0, 8)
        self.assertIn("output too large", res["toast"])
        pid = int((self.dir / "pid").read_text())
        self.assertTrue(wait_dead(pid))

    async def test_stderr_flood_is_tolerated(self):
        p = self.plugin("head -c 30000000 /dev/zero | tr '\\0' e >&2\necho '{\"toast\":\"ok\"}'\n")
        res = await self.run_p(p, limit=30)
        self.assertEqual(res["toast"], "ok")


class TestHtmlStrip(Base):  # F2
    def test_fit_malformed_html_is_fast_and_bounded(self):
        t0 = time.perf_counter()
        text, mode = bot.fit("<" * 160000, "HTML")
        dt = time.perf_counter() - t0
        print(f"  fit('<'*160000, HTML): {dt*1000:.1f} ms")
        self.assertLess(dt, 0.1)
        self.assertLessEqual(len(text), 4096)

    def test_fit_other_pathological_inputs_fast(self):
        for s in ("<a " * 60000, "&" * 160000, "<" + "a" * 160000, "<a>" * 60000):
            t0 = time.perf_counter()
            text, _ = bot.fit(s, "HTML")
            self.assertLess(time.perf_counter() - t0, 0.1)
            self.assertLessEqual(len(text), 4096)

    def test_fit_still_strips_tags(self):
        text, mode = bot.fit("<b>hi</b> &amp; " + "x" * 5000, "HTML")
        self.assertIsNone(mode)
        self.assertTrue(text.startswith("hi & x"))

    async def test_event_loop_not_blocked(self):
        gaps = []

        async def beat():
            last = time.perf_counter()
            while True:
                await asyncio.sleep(0.02)
                now = time.perf_counter()
                gaps.append(now - last)
                last = now

        class Msg:
            chat_id = 1
            message_id = 2
            async def edit_text(self, text, **k): self.t = text

        hb = asyncio.ensure_future(beat())
        await asyncio.sleep(0.1)
        await bot.apply_plugin_result(
            {"edit_text": "<" * 160000, "parse_mode": "HTML", "_answered": True}, Msg(), None)
        await asyncio.sleep(0.1)
        hb.cancel()
        print(f"  max loop gap: {max(gaps)*1000:.1f} ms")
        self.assertLess(max(gaps), 0.1)


class TestReap(Base):  # F3
    async def test_child_left_after_normal_exit_is_killed(self):
        p = self.plugin("sleep 300 </dev/null >/dev/null 2>&1 &\necho $! > %s/pid\n"
                        "echo '{\"toast\":\"ok\"}'\n" % self.dir)
        res = await self.run_p(p)
        self.assertEqual(res["toast"], "ok")
        self.assertTrue(wait_dead(int((self.dir / "pid").read_text())))

    async def test_child_left_after_nonzero_exit_is_killed(self):
        p = self.plugin("sleep 300 </dev/null >/dev/null 2>&1 &\necho $! > %s/pid\nexit 3\n" % self.dir)
        res = await self.run_p(p)
        self.assertIn("failed", res["toast"])
        self.assertTrue(wait_dead(int((self.dir / "pid").read_text())))

    async def test_child_left_after_bad_output_is_killed(self):
        p = self.plugin("sleep 300 </dev/null >/dev/null 2>&1 &\necho $! > %s/pid\necho nope\n" % self.dir)
        res = await self.run_p(p)
        self.assertIn("no JSON", res["toast"])
        self.assertTrue(wait_dead(int((self.dir / "pid").read_text())))

    async def test_child_holding_stdout_does_not_stall_the_bot(self):
        p = self.plugin("sleep 300 &\necho $! > %s/pid\necho '{\"toast\":\"ok\"}'\n" % self.dir)
        t0 = time.time()
        res = await self.run_p(p, limit=15)
        self.assertLess(time.time() - t0, 5)
        self.assertEqual(res["toast"], "ok")
        self.assertTrue(wait_dead(int((self.dir / "pid").read_text())))


class TestEscapes(Base):  # F4
    async def test_nul_in_reply_text(self):
        p = self.plugin("echo '{\"toast\":\"ok\"}'\n")
        res = await self.run_p(p, mode="reply", arg="a\x00b")
        self.assertTrue(res.get("toast"))
        self.assertNotEqual(res["toast"], "ok")

    async def test_deeply_nested_json(self):
        p = self.plugin("head -c 900000 /dev/zero | tr '\\0' '['\n")
        res = await self.run_p(p)
        self.assertTrue(res.get("toast"))

    def test_non_string_parse_mode(self):
        for pm in (5, ["HTML"], {"a": 1}):
            text, mode = bot.fit("x" * 5000, pm)
            self.assertLessEqual(len(text), 4096)
            self.assertIsNone(mode)

    async def test_weird_result_shapes_still_toast(self):
        sent = []

        class Msg:
            chat_id = 1
            message_id = 2
            async def edit_text(self, text, **k): sent.append(text)

        class B:
            async def send_message(self, *a, **k): sent.append(a[1])

        for res in ({"edit_text": "x" * 5000, "parse_mode": 5, "toast": "t", "_answered": True},
                    {"edit_text": "x", "buttons": 7, "toast": "t", "_answered": True},
                    {"edit_text": "x", "buttons": [[5]], "toast": "t", "_answered": True}):
            await bot.apply_plugin_result(res, Msg(), B())


class TestLostEdit(Base):  # round 2 P2
    async def test_failed_edit_delivers_its_text(self):
        sent = []

        class Msg:
            chat_id = 1
            message_id = 2
            async def edit_text(self, text, **k): raise Exception("Message to edit not found")

        class B:
            async def send_message(self, *a, **k): sent.append(a[1])

        res = {"edit_text": "<b>unique result content</b>", "parse_mode": "HTML", "_answered": True}
        ok = await bot.apply_plugin_result(res, Msg(), B())
        self.assertTrue(any("unique result content" in s for s in sent), sent)
        self.assertFalse(any("<b>" in s for s in sent), sent)
        self.assertTrue(ok)


class TestRound4(Base):
    def test_huge_numeric_entity_in_fit(self):
        text, mode = bot.fit("&#" + "9" * 5000 + ";", "HTML")
        self.assertIsNone(mode)
        self.assertTrue(text)

    async def test_huge_numeric_entity_in_refused_edit(self):
        sent = []

        class Msg:
            chat_id = 1
            message_id = 2
            async def edit_text(self, text, **k): raise Exception("Message to edit not found")

        class B:
            async def send_message(self, *a, **k): sent.append(a[1])

        res = {"edit_text": "card &#" + "9" * 5000 + ";", "parse_mode": "HTML", "_answered": True}
        await bot.apply_plugin_result(res, Msg(), B())
        self.assertTrue(any("card" in s for s in sent), sent)

    async def test_sighup_in_spawn_window_is_deferred_until_registered(self):
        # A SIGHUP arriving while a plugin is being spawned is held and re-raised
        # once its group is registered, so the kill finds it.
        kills, raised = [], []
        orig = (bot.kill_plugin_groups, signal.raise_signal, signal.signal, asyncio.create_subprocess_exec)

        def fake_raise(s):
            raised.append(s)
            if len(raised) == 1:            # the deferred delivery: run the handler now
                bot.on_sighup(s, None)

        async def spawn_with_signal(*a, **k):
            bot.on_sighup(signal.SIGHUP, None)    # arrives inside the window
            return await orig[3](*a, **k)

        bot.kill_plugin_groups = lambda: kills.append(set(bot.PLUGIN_GROUPS))
        signal.raise_signal = fake_raise
        signal.signal = lambda *a: None
        asyncio.create_subprocess_exec = spawn_with_signal
        try:
            p = self.plugin("echo '{\"toast\":\"ok\"}'\n")
            await self.run_p(p)
        finally:
            bot.kill_plugin_groups, signal.raise_signal, signal.signal, asyncio.create_subprocess_exec = orig
            bot.PENDING_STOP[0] = None
        self.assertTrue(kills and kills[0], (kills, raised))

    async def test_plugin_starts_with_no_blocked_signals(self):
        p = self.plugin("exec %s -c 'import signal, json; print(json.dumps({\"toast\": str(sorted(int(s) for s in signal.pthread_sigmask(signal.SIG_BLOCK, [])))}))'\n" % sys.executable)
        res = await self.run_p(p)
        self.assertEqual(res.get("toast"), "[]", res)


class TestShutdown(Base):  # F5
    async def test_kill_plugin_groups_stops_running_plugin(self):
        p = self.plugin("sleep 300 &\necho $! > %s/pid\nwait\n" % self.dir)
        task = asyncio.ensure_future(bot.run_plugin(p, "callback", "x", {}))
        for _ in range(100):
            await asyncio.sleep(0.05)
            if bot.PLUGIN_GROUPS and (self.dir / "pid").exists():
                break
        self.assertTrue(bot.PLUGIN_GROUPS)
        bot.kill_plugin_groups()
        res = await asyncio.wait_for(task, 10)
        self.assertTrue(res.get("toast"))
        self.assertTrue(wait_dead(int((self.dir / "pid").read_text())))
        self.assertFalse(bot.PLUGIN_GROUPS)

    async def test_group_set_empty_after_normal_run(self):
        p = self.plugin("echo '{\"toast\":\"ok\"}'\n")
        await self.run_p(p)
        self.assertFalse(bot.PLUGIN_GROUPS)

    def test_sighup_kills_groups_then_dies_as_before(self):
        # `megavibe remote --stop` (tmux kill-session) must not wait for a graceful
        # stop: the old process would keep the bot's lock while a question is in flight.
        calls = []
        orig_kill, orig_raise, orig_sig = bot.kill_plugin_groups, signal.raise_signal, signal.signal
        bot.kill_plugin_groups = lambda: calls.append("kill")
        signal.raise_signal = lambda s: calls.append(("raise", s))
        signal.signal = lambda s, h: calls.append(("handler", s, h))
        try:
            bot.on_sighup(signal.SIGHUP, None)
        finally:
            bot.kill_plugin_groups, signal.raise_signal, signal.signal = orig_kill, orig_raise, orig_sig
        self.assertEqual(calls, ["kill", ("handler", signal.SIGHUP, signal.SIG_DFL), ("raise", signal.SIGHUP)])

    async def test_no_plugin_starts_once_stopping(self):
        p = self.plugin("touch %s/started\necho '{\"toast\":\"ok\"}'\n" % self.dir)
        bot.STOPPING = True
        try:
            res = await self.run_p(p)
        finally:
            bot.STOPPING = False
        self.assertFalse((self.dir / "started").exists())
        self.assertIn("shutting down", res.get("toast", ""))

    def test_stop_signal_kills_groups_before_shutdown_waits(self):
        calls = []
        orig_kill = bot.kill_plugin_groups
        bot.kill_plugin_groups = lambda: calls.append("kill")
        try:
            with self.assertRaises(KeyboardInterrupt):
                bot.on_stop_signal(signal.SIGTERM, None)
        finally:
            bot.kill_plugin_groups = orig_kill
        self.assertEqual(calls, ["kill"])

    def test_polling_leaves_signals_to_the_bot(self):
        src = (ROOT / "telegram-bot.py").read_text()
        self.assertIn("stop_signals=None", src)
        self.assertIn("signal.signal(signal.SIGTERM, on_stop_signal)", src)
        self.assertIn("signal.signal(signal.SIGINT, on_stop_signal)", src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
