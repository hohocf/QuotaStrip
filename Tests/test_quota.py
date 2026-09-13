import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('quota', Path(__file__).resolve().parents[1] / 'Resources/quota.py')
quota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quota)


class ServiceSelectionTests(unittest.TestCase):
    def test_all_selections_including_force(self):
        data = {'five': {'pct': 12, 'reset': 9999999999}, 'week': {'pct': 34, 'reset': 9999999999}}
        for claude in (False, True):
            for codex in (False, True):
                for force in (False, True):
                    args = ['quota.py', 'json'] + ([] if claude else ['--no-claude']) + ([] if codex else ['--no-codex']) + (['--force'] if force else [])
                    with self.subTest(claude=claude, codex=codex, force=force), patch('sys.argv', args), patch.object(quota, 'claude_fetch', return_value=(data, False)) as cc, patch.object(quota, 'codex_fetch', return_value=data) as cx, patch.object(quota, 'attention_flag', return_value=False) as attention, patch.object(quota, 'claude_waiting', return_value=False) as waiting, contextlib.redirect_stdout(io.StringIO()) as output:
                        quota.main()
                        result = json.loads(output.getvalue())
                        self.assertEqual(cc.call_count, int(claude))
                        self.assertEqual(cx.call_count, int(codex))
                        self.assertEqual(attention.call_count, int(claude))
                        self.assertEqual(waiting.call_count, int(claude))
                        self.assertEqual(result['claude']['ok'], claude)
                        self.assertEqual(result['codex']['ok'], codex)
                        if claude:
                            cc.assert_called_once_with(force=force)

    def test_codex_reset_is_local_even_on_forced_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'session.jsonl'
            log.write_text(json.dumps({'payload': {'rate_limits': {'primary': {'used_percent': 23, 'resets_at': 2000, 'window_minutes': 300}, 'secondary': {'used_percent': 45, 'resets_at': 3000, 'window_minutes': 10080}}}}) + '\n')
            with patch('sys.argv', ['quota.py', 'json', '--no-claude', '--force']), patch.object(quota.glob, 'glob', return_value=[str(log)]), patch.object(quota.time, 'time', return_value=1000), patch.object(quota, 'attention_flag', return_value=False), patch.object(quota.urllib.request, 'urlopen', side_effect=AssertionError('Network forbidden')), patch.object(quota.subprocess, 'run', side_effect=AssertionError('Credentials forbidden')), contextlib.redirect_stdout(io.StringIO()) as output:
                quota.main()
                codex = json.loads(output.getvalue())['codex']
                self.assertEqual(codex['windows'][0], {'pct': 23, 'reset': 2000, 'label': '5h', 'minutes': 300})
                self.assertEqual(codex['windows'][1], {'pct': 45, 'reset': 3000, 'label': '7d', 'minutes': 10080})

    def test_week_only_account_has_one_correctly_labeled_window(self):
        windows = quota.codex_windows({'primary': {'used_percent': 2, 'window_minutes': 10080, 'resets_at': 9999999999}, 'secondary': None})
        self.assertEqual(windows, [{'pct': 2, 'reset': 9999999999, 'label': '7d', 'minutes': 10080}])
        payload = quota.service_json({'windows': windows})
        self.assertNotIn('five', payload)
        self.assertNotIn('week', payload)
        self.assertEqual(quota.fmt_text('CDX', {'windows': windows}, False), '🟢CDX 7d:2')

    def test_missing_and_expired_usage_are_not_zero(self):
        self.assertEqual(quota.codex_windows({'primary': None, 'secondary': None}), [])
        with patch.object(quota.time, 'time', return_value=2000):
            window = quota.codex_window({'used_percent': 90, 'window_minutes': 10080, 'resets_at': 2000})
            self.assertIsNone(window['pct'])
            self.assertIsNone(window['reset'])
            self.assertEqual(window['label'], '7d')
            self.assertIn('7d:—', quota.fmt_text('CDX', {'windows': [window]}, False))
        self.assertIsNone(quota.codex_window({'window_minutes': 300})['pct'])
        self.assertEqual(quota.codex_window({'window_minutes': 300, 'used_percent': 0})['pct'], 0)

    def test_duration_not_position_defines_label(self):
        windows = quota.codex_windows({'primary': {'window_minutes': 10080}, 'secondary': {'window_minutes': 300}})
        self.assertEqual([w['label'] for w in windows], ['7d', '5h'])
        self.assertEqual(quota.codex_window({'used_percent': 2})['label'], '?')

    def test_account_switches_follow_local_plan_and_windows(self):
        five = {'used_percent': 10, 'window_minutes': 300, 'resets_at': 9999999999}
        week = {'used_percent': 20, 'window_minutes': 10080, 'resets_at': 9999999999}
        # Switch in both directions; Pro may also report two actual windows.
        for plan, primary, secondary, labels in [
            ('plus', five, week, ['5h', '7d']),
            ('prolite', week, None, ['7d']),
            ('pro', five, week, ['5h', '7d']),
            ('plus', five, week, ['5h', '7d']),
            (None, week, None, ['7d']),
        ]:
            with self.subTest(plan=plan), patch.object(quota.glob, 'glob', return_value=['local.jsonl']), patch.object(quota.os.path, 'getmtime', return_value=1000), patch.object(quota, 'find_rate_limits', return_value={'plan_type': plan, 'primary': primary, 'secondary': secondary}), patch.object(quota, 'attention_flag', return_value=False), patch.object(quota.urllib.request, 'urlopen', side_effect=AssertionError('Network forbidden')), patch.object(quota.subprocess, 'run', side_effect=AssertionError('Credentials forbidden')):
                payload = quota.service_json(quota.codex_fetch())
                self.assertEqual(payload['plan_type'], plan)
                self.assertEqual([w['label'] for w in payload['windows']], labels)


if __name__ == '__main__':
    unittest.main()
