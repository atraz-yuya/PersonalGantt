import datetime as dt
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

import update_iphone as update


class UpdateTests(unittest.TestCase):
    def profile(self):
        return {'LocalProvision': True, 'Platform': ['iOS'],
                'ExpirationDate': dt.datetime.now(update.UTC) + dt.timedelta(days=7),
                'ProvisionedDevices': ['phone-udid'], 'Entitlements': {
                    'application-identifier': 'TESTTEAM01.' + update.BUNDLE,
                    'com.apple.developer.team-identifier': 'TESTTEAM01', 'get-task-allow': True}}

    def device(self, modern=True, transport='wired'):
        hw = {'platform': 'iOS', 'udid': 'phone-udid'}
        conn = {'transportType': transport, 'pairingState': 'paired'}
        state = {'name': 'Test Phone', 'bootState': 'booted'}
        if modern:
            return {'identifier': 'device-id', 'properties': {'hardware': hw, 'connection': conn, 'state': state}}
        return {'identifier': 'device-id', 'hardwareProperties': hw,
                'connectionProperties': conn, 'deviceProperties': state}

    def seed(self, folder):
        path = folder / 'Library/Application Support/PersonalGantt'
        path.mkdir(parents=True)
        for name in ['LocalPlan.store', 'LocalPlan.store-wal', 'ReminderMetadata.json', 'LocalPlan.store-shm']:
            (path / name).write_bytes(b'test-' + name.encode())
        prefs = folder / ('Library/Preferences/' + update.BUNDLE + '.plist')
        prefs.parent.mkdir(parents=True)
        prefs.write_bytes(b'settings')
        return path

    def test_modern_and_legacy_exclude_even_booted_simulator(self):
        for modern in [True, False]:
            payload = {'devices': [self.device(modern), self.device(modern, 'sameMachine')]}
            self.assertEqual(len(update.devices_from(payload)), 1)

    def test_multiple_devices_require_explicit_selection(self):
        phones = [{'id': 'one', 'udid': 'u1'}, {'id': 'two', 'udid': 'u2'}]
        with self.assertRaises(update.UpdateError):
            update.choose_device(phones)
        self.assertEqual(update.choose_device(phones, 'u2')['id'], 'two')
        with self.assertRaises(update.UpdateError):
            update.choose_device([], 'u1')

    def test_wrong_team_bundle_device_and_expiry_rejected(self):
        for mutate in [lambda p: p['Entitlements'].update({'application-identifier': 'TESTTEAM01.other'}),
                       lambda p: p['Entitlements'].update({'com.apple.developer.team-identifier': 'OTHERTEAM1'}),
                       lambda p: p.update({'ProvisionedDevices': ['other']}),
                       lambda p: p.update({'ExpirationDate': dt.datetime.now(update.UTC) - dt.timedelta(days=1)}),
                       lambda p: p.update({'ExpirationDate': dt.datetime.now(update.UTC) + dt.timedelta(hours=24)})]:
            p = self.profile()
            mutate(p)
            with self.assertRaises(update.UpdateError):
                update.validate_profile(p, 'TESTTEAM01', 'phone-udid')
        self.assertGreater(update.validate_profile(self.profile(), 'TESTTEAM01', 'phone-udid'), dt.datetime.now(update.UTC))

    def test_other_apps_or_mac_profiles_are_not_refreshed(self):
        p = self.profile()
        self.assertTrue(update.profile_matches(p, 'TESTTEAM01'))
        p['Platform'] = ['OSX']
        self.assertFalse(update.profile_matches(p, 'TESTTEAM01'))
        p['Platform'] = ['iOS']
        p['LocalProvision'] = False
        self.assertFalse(update.profile_matches(p, 'TESTTEAM01'))

    def test_database_wal_and_preferences_changes_detected(self):
        for name in ['Library/Application Support/PersonalGantt/LocalPlan.store',
                     'Library/Application Support/PersonalGantt/LocalPlan.store-wal',
                     'Library/Preferences/' + update.BUNDLE + '.plist']:
            with tempfile.TemporaryDirectory() as temp:
                before, after = Path(temp) / 'before', Path(temp) / 'after'
                self.seed(before)
                self.seed(after)
                self.assertEqual(update.verify_data(before, after), 4)
                (after / name).write_bytes(b'changed')
                with self.assertRaises(update.UpdateError):
                    update.verify_data(before, after)
                (after / name).unlink()
                with self.assertRaises(update.UpdateError):
                    update.verify_data(before, after)

    def test_missing_database_rejected_and_shm_is_ephemeral(self):
        with tempfile.TemporaryDirectory() as temp:
            before, after = Path(temp) / 'before', Path(temp) / 'after'
            with self.assertRaises(update.UpdateError):
                update.verify_data(before, after)
            self.seed(before)
            path = self.seed(after)
            (path / 'LocalPlan.store-shm').write_bytes(b'different')
            self.assertEqual(update.verify_data(before, after), 4)

    def test_cache_restore_does_not_overwrite_new_profile(self):
        with tempfile.TemporaryDirectory() as temp:
            original, backup = Path(temp) / 'original', Path(temp) / 'backup'
            backup.write_bytes(b'old')
            update.restore_profiles([(original, backup)])
            self.assertEqual(original.read_bytes(), b'old')
            original.write_bytes(b'new')
            update.restore_profiles([(original, backup)])
            self.assertEqual(original.read_bytes(), b'new')

    def test_same_expiry_is_not_reported_as_extended(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(update, 'PRIVATE', Path(temp)):
            runner = update.Updater(SimpleNamespace(non_interactive=True))
            runner.team = 'TESTTEAM01'
            runner.device = {'udid': 'phone-udid'}
            profile = self.profile()
            runner.refresh_profiles = lambda: profile['ExpirationDate']
            runner.decode_profile = lambda path: profile
            def command(*args, **kwargs):
                if args[1] == 'build':
                    self.assertFalse((app / 'stale-sealed-resource').exists())
                    app.mkdir(parents=True, exist_ok=True)
                    (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': update.BUNDLE}))
            runner.command = command
            runner.entitlements = lambda app: plistlib.dumps(profile['Entitlements'])
            app = Path(temp) / 'DerivedData/Build/Products/Debug-iphoneos/PersonalGantt.app'
            app.mkdir(parents=True)
            (app / 'stale-sealed-resource').write_bytes(b'old-signature')
            runner.build()
            self.assertFalse(runner.state['expiry_extended'])

    def test_locked_device_stops_without_install(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(update, 'PRIVATE', Path(temp)):
            runner = update.Updater(SimpleNamespace(non_interactive=True))
            calls = []
            runner.device_ctl = lambda args, *rest: calls.append(args) or {'passcodeRequired': True}
            with self.assertRaisesRegex(update.UpdateError, 'ロックを解除'):
                runner.install(Path('app'))
            self.assertEqual(calls, [['device', 'info', 'lockState']])

    def test_launch_options_precede_bundle_identifier(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(update, 'PRIVATE', Path(temp)):
            runner = update.Updater(SimpleNamespace(non_interactive=True))
            runner.device = {'id': 'device-id'}
            def command(command, label, timeout):
                # 実CLIはbundle IDより後をアプリ引数とみなし、--deviceを認識しない。
                self.assertEqual(command[-1], update.BUNDLE)
                self.assertLess(command.index('--device'), command.index(update.BUNDLE))
                self.assertLess(command.index('--json-output'), command.index(update.BUNDLE))
                Path(command[command.index('--json-output') + 1]).write_text('{"result": {}}')
            runner.command = command
            runner.device_ctl(['device', 'process', 'launch', update.BUNDLE], 'launch')

    def test_backup_failure_never_installs(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(update, 'PRIVATE', Path(temp)):
            runner = update.Updater(SimpleNamespace(non_interactive=True))
            runner.unlocked = lambda: None
            calls = []
            runner.device_ctl = lambda args, *rest: calls.append(args) or {'runningProcesses': []}
            def fail(*args):
                raise update.UpdateError('backup failed')
            runner.backup = fail
            with self.assertRaises(update.UpdateError):
                runner.install(Path('app'))
            self.assertFalse(any('install' in c for c in calls))

    def test_data_mismatch_stops_before_launch(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(update, 'PRIVATE', Path(temp)):
            runner = update.Updater(SimpleNamespace(non_interactive=True))
            runner.unlocked = lambda: None
            calls = []
            runner.device_ctl = lambda args, *rest: calls.append(args) or {'runningProcesses': []}
            def backup(folder, label):
                path = self.seed(folder)
                if label == 'backup-after':
                    (path / 'LocalPlan.store').write_bytes(b'changed')
            runner.backup = backup
            with self.assertRaises(update.UpdateError):
                runner.install(Path('app'))
            self.assertTrue(any('install' in c for c in calls))
            self.assertFalse(any('launch' in c for c in calls))
            self.assertEqual(json.loads((Path(temp) / 'state.json').read_text())['phase'], 'installed')

    def test_launch_failure_leaves_manual_trust_step(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(update, 'PRIVATE', Path(temp)):
            runner = update.Updater(SimpleNamespace(non_interactive=True))
            runner.unlocked = lambda: None
            def fail(*args):
                raise update.UpdateError('untrusted')
            runner.device_ctl = fail
            runner.state = {'phase': 'verified-awaiting-launch'}
            with self.assertRaisesRegex(update.UpdateError, 'VPNとデバイス管理'):
                runner.launch()
            self.assertEqual(runner.state['phase'], 'verified-awaiting-launch')


if __name__ == '__main__':
    unittest.main()
