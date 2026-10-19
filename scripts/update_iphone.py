#!/usr/bin/env python3
"""Personal Teamの同一アプリをバックアップして上書き更新する。Python標準ライブラリのみ。"""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / 'PrivateVerification' / 'iPhoneUpdate'
BUNDLE = 'com.atraz.PersonalGantt'
UTC = dt.timezone.utc


class UpdateError(Exception):
    pass


def utc(date):
    return date.replace(tzinfo=UTC) if date.tzinfo is None else date.astimezone(UTC)


def say(message):
    print(message, flush=True)


def save(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temp.replace(path)


def devices_from(payload):
    devices = []
    for raw in payload.get('devices', []):
        props = raw.get('properties', {})
        hw = props.get('hardware', raw.get('hardwareProperties', {}))
        conn = props.get('connection', raw.get('connectionProperties', {}))
        state = props.get('state', raw.get('deviceProperties', {}))
        # sameMachineにはXcodeの仮想端末も含まれる。物理USB端末だけを対象にする。
        if (conn.get('transportType') != 'wired' or hw.get('platform') != 'iOS'
                or state.get('bootState') != 'booted' or conn.get('pairingState') != 'paired'):
            continue
        devices.append({'id': raw['identifier'], 'udid': hw.get('udid'),
                        'name': state.get('name', 'iPhone / iPad')})
    return devices


def choose_device(devices, requested=None):
    if requested:
        devices = [x for x in devices if requested in (x['id'], x['udid'])]
    if not devices:
        raise UpdateError('USB接続した実機が見つかりません。ケーブル・ロック解除・Macへの信頼を確認してください。')
    if len(devices) != 1:
        raise UpdateError('複数の実機が接続されています。更新する1台だけをUSB接続するか、--deviceで指定してください。')
    if not devices[0]['udid']:
        raise UpdateError('端末の識別情報を取得できません。Xcodeで接続を確認してください。')
    return devices[0]


def profile_matches(profile, team):
    ent = profile.get('Entitlements', {})
    return (profile.get('LocalProvision') is True
            and 'iOS' in profile.get('Platform', [])
            and ent.get('com.apple.developer.team-identifier') == team
            and ent.get('application-identifier') == team + '.' + BUNDLE)


def validate_profile(profile, team, udid, now=None):
    now = now or dt.datetime.now(UTC)
    if not profile_matches(profile, team):
        raise UpdateError('署名のTeamまたはアプリIDが一致しません。更新を中止しました。')
    if udid not in profile.get('ProvisionedDevices', []):
        raise UpdateError('署名に対象端末が含まれていません。更新を中止しました。')
    expiry = utc(profile['ExpirationDate'])
    if expiry <= now + dt.timedelta(hours=48):
        raise UpdateError('新しい署名の残り期限が48時間以下です。Xcodeのアカウントと署名を確認してください。')
    return expiry


def data_hashes(folder):
    """SQLiteの本体/WALとアプリの永続データ・設定を比較。OSの一時ファイルは除く。"""
    result = {}
    for parent in [folder / 'Library/Application Support/PersonalGantt',
                   folder / 'Documents']:
        if parent.exists():
            for path in parent.rglob('*'):
                if path.is_file() and not path.name.endswith('-shm') and path.name != '.DS_Store':
                    result[str(path.relative_to(folder))] = hashlib.sha256(path.read_bytes()).hexdigest()
    prefs = folder / ('Library/Preferences/' + BUNDLE + '.plist')
    if prefs.is_file():
        result[str(prefs.relative_to(folder))] = hashlib.sha256(prefs.read_bytes()).hexdigest()
    return result


def verify_data(before, after):
    baseline = data_hashes(before)
    if not any(Path(x).name == 'LocalPlan.store' for x in baseline):
        raise UpdateError('バックアップに保存データ本体がありません。インストールを中止します。')
    actual = data_hashes(after)
    if any(actual.get(key) != value for key, value in baseline.items()):
        raise UpdateError('更新前後の保存データに差があります。起動せず停止しました。バックアップを保持しています。')
    return len(baseline)


def restore_profiles(moved):
    for original, backup in moved:
        if not original.exists() and backup.exists():
            shutil.copy2(backup, original)


class Updater:
    def __init__(self, args):
        self.args = args
        PRIVATE.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(PRIVATE, 0o700)
        self.run_dir = PRIVATE / dt.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        self.run_dir.mkdir(mode=0o700)
        self.counter = 0
        self.device = None
        self.team = None
        self.state = {}
        self.moved = []
        self.profile_ready = False

    def command(self, command, label, timeout=90, capture=False):
        self.counter += 1
        log = self.run_dir / ('%02d-%s.log' % (self.counter, label))
        with log.open('wb') as out:
            proc = subprocess.Popen(command, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT)
            start = time.monotonic()
            try:
                while True:
                    try:
                        rc = proc.wait(timeout=min(30, timeout))
                        break
                    except subprocess.TimeoutExpired:
                        if time.monotonic() - start >= timeout:
                            proc.terminate()
                            try:
                                proc.wait(timeout=10)
                            except subprocess.TimeoutExpired:
                                proc.kill()
                                proc.wait()
                            raise UpdateError(label + ' が時間切れです。詳細は実行ログを確認してください。')
                        say(label + ' を実行中…')
            except BaseException:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                raise
        if rc:
            raise UpdateError(label + ' に失敗しました。詳細は実行ログを確認してください。')
        return log.read_bytes() if capture else None

    def ctl(self, arguments, label, timeout=45):
        output = self.run_dir / (label + '.json')
        # launchのbundle ID以降はアプリ自身の引数として解釈される。
        # devicectlのオプションは必ず位置引数より前へ置く。
        depth = 3 if arguments[0] == 'device' else 2
        self.command(['xcrun', 'devicectl'] + arguments[:depth] +
                     ['--timeout', str(timeout), '--json-output', str(output)] +
                     arguments[depth:], label, timeout + 15)
        return json.loads(output.read_text())['result']

    def device_ctl(self, arguments, label, timeout=45):
        return self.ctl(arguments[:3] + ['--device', self.device['id']] + arguments[3:], label, timeout)

    def prompt(self, message):
        if self.args.non_interactive or not sys.stdin.isatty():
            raise UpdateError(message + '\n準備ができたら同じコマンドを再実行してください。')
        input(message + '\n準備ができたらEnter（中止はCtrl+C）: ')

    def unlocked(self):
        for attempt in range(4):
            result = self.device_ctl(['device', 'info', 'lockState'], 'lock-%d' % attempt)
            if result.get('passcodeRequired') is False and result.get('unlockedSinceBoot') is True:
                return
            if attempt == 3:
                break
            self.prompt('iPhoneのロックを解除し、ホーム画面を表示したままにしてください。')
        raise UpdateError('ロック解除を確認できませんでした。')

    def preflight(self):
        if sys.platform != 'darwin':
            raise UpdateError('このコマンドはXcodeを設定したMacで実行してください。')
        signing = ROOT / 'Config/Signing.local.xcconfig'
        match = re.search(r'^\s*DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\s*$',
                          signing.read_text() if signing.exists() else '', re.M)
        if not match:
            raise UpdateError('Config/Signing.local.xcconfigにご自身のTeam IDを設定してください。')
        self.team = match.group(1)
        self.command(['xcodebuild', '-version'], 'xcode-version')
        result = self.ctl(['list', 'devices'], 'devices', 30)
        self.device = choose_device(devices_from(result), self.args.device)
        say('USB接続した実機を確認しました。')
        self.unlocked()
        apps = self.device_ctl(['device', 'info', 'apps', '--bundle-id', BUNDLE,
                                '--include-container-paths'], 'existing-app').get('apps', [])
        if len(apps) != 1 or not apps[0].get('containerAccessible') or not apps[0].get('dataContainerPath'):
            raise UpdateError('既存アプリと保存領域を確認できません。初回インストールはXcodeで行ってください。')
        self.state = {'device': self.device, 'run_directory': str(self.run_dir), 'phase': 'preflight'}

    def decode_profile(self, path):
        return plistlib.loads(self.command(['security', 'cms', '-D', '-i', str(path)],
                                           'decode-profile', capture=True))

    def refresh_profiles(self):
        latest = None
        cache = self.run_dir / 'profile-cache-backup'
        cache.mkdir()
        roots = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
                 Path.home() / 'Library/MobileDevice/Provisioning Profiles']
        for index, root in enumerate(roots):
            if not root.exists():
                continue
            for path in root.glob('*.mobileprovision'):
                profile = self.decode_profile(path)
                if profile_matches(profile, self.team):
                    expiry = utc(profile['ExpirationDate'])
                    latest = max(latest, expiry) if latest else expiry
                    backup = cache / ('%d-%s' % (index, path.name))
                    # Record before moving, so interruption/failure can restore the cache.
                    self.moved.append((path, backup))
                    save(cache / 'manifest.json', [{'original': str(a), 'backup': str(b)} for a, b in self.moved])
                    shutil.move(str(path), str(backup))
        return latest

    def build(self):
        previous = self.refresh_profiles()
        say('新しい署名を要求して実機用アプリをビルドします。')
        derived = PRIVATE / 'DerivedData'
        app = derived / 'Build/Products/Debug-iphoneos/PersonalGantt.app'
        # プロファイルの差し替えを増分ビルドが署名更新として扱わない場合がある。
        # 生成されたアプリだけを作り直し、ソース・コンパイル済み依存物は保持する。
        if app.exists():
            shutil.rmtree(app)
        command = ['xcodebuild', '-project', 'PersonalGantt.xcodeproj', '-scheme', 'PersonalGantt',
                   '-configuration', 'Debug', '-destination', 'generic/platform=iOS',
                   '-derivedDataPath', str(derived), '-allowProvisioningUpdates',
                   '-allowProvisioningDeviceRegistration', '-onlyUsePackageVersionsFromResolvedFile',
                   '-skipPackageUpdates']
        caches = sorted((Path.home() / 'Library/Developer/Xcode/DerivedData').glob('PersonalGantt*/SourcePackages'))
        for cache in caches:
            if (cache / 'checkouts/swift-certificates/Package.swift').is_file():
                command += ['-clonedSourcePackagesDirPath', str(cache)]
                break
        self.command(command + ['build'], 'build', 1200)
        profile = self.decode_profile(app / 'embedded.mobileprovision')
        expiry = validate_profile(profile, self.team, self.device['udid'])
        self.command(['codesign', '--verify', '--deep', '--strict', str(app)], 'verify-signature')
        ent = plistlib.loads(self.entitlements(app))
        for key in ['application-identifier', 'com.apple.developer.team-identifier', 'get-task-allow']:
            if ent.get(key) != profile['Entitlements'].get(key):
                raise UpdateError('署名とプロファイルの権限が一致しません。')
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != BUNDLE:
            raise UpdateError('ビルドされたアプリIDが一致しません。')
        self.state.update(app=str(app), expires=expiry.isoformat(),
                          expiry_extended=previous is None or expiry > previous)
        if previous and expiry <= previous:
            say('署名期限は前回と同じです。実際の期限を最後に表示します。')
        say('署名検証完了。有効期限: ' + expiry.astimezone().strftime('%Y/%m/%d %H:%M %Z'))
        self.profile_ready = True
        return app

    def entitlements(self, app):
        # codesignの診断はstderrにも出るためXML部分だけを抽出する。
        data = self.command(['codesign', '-d', '--entitlements', ':-', str(app)],
                            'signature-entitlements', capture=True)
        start = data.find(b'<?xml')
        end = data.find(b'</plist>')
        if start < 0 or end < start:
            raise UpdateError('署名の権限を読み取れませんでした。')
        return data[start:end + len(b'</plist>')]

    def backup(self, destination, label):
        self.device_ctl(['device', 'copy', 'from', '--domain-type', 'appDataContainer',
                         '--domain-identifier', BUNDLE, '--source', '.',
                         '--destination', str(destination)], label, 90)

    def install(self, app):
        self.unlocked()
        processes = self.device_ctl(['device', 'info', 'processes', '--search', 'PersonalGantt'],
                                    'processes-before').get('runningProcesses', [])
        for process in processes:
            if str(process.get('executable', '')).endswith('/PersonalGantt.app/PersonalGantt'):
                self.device_ctl(['device', 'process', 'terminate', '--pid', str(process['processIdentifier'])],
                                'terminate')
        remaining = self.device_ctl(['device', 'info', 'processes', '--search', 'PersonalGantt'],
                                    'processes-stopped').get('runningProcesses', [])
        if any(str(x.get('executable', '')).endswith('/PersonalGantt.app/PersonalGantt') for x in remaining):
            raise UpdateError('アプリの終了を確認できません。iPhoneでアプリを閉じて再実行してください。')
        say('更新前のデータをバックアップしています。')
        before = self.run_dir / 'app-data-before'
        self.backup(before, 'backup-before')
        verify_data(before, before)  # 本体がない不完全なバックアップでは更新しない。
        self.state.update(backup=str(before), phase='backed-up')
        save(self.run_dir / 'result.json', self.state)
        save(PRIVATE / 'state.json', self.state)
        say('同じアプリへ上書きインストールしています。')
        self.device_ctl(['device', 'install', 'app', str(app)], 'install', 120)
        self.state['phase'] = 'installed'
        save(PRIVATE / 'state.json', self.state)
        after = self.run_dir / 'app-data-after'
        self.backup(after, 'backup-after')
        count = verify_data(before, after)
        self.state.update(phase='verified-awaiting-launch', verified_files=count)
        save(PRIVATE / 'state.json', self.state)
        say('保存データの保持を確認しました。')

    def launch(self):
        self.unlocked()
        for attempt in range(4):
            try:
                result = self.device_ctl(['device', 'process', 'launch', BUNDLE], 'launch-%d' % attempt)
            except UpdateError:
                if attempt == 3:
                    break
                self.prompt('起動できませんでした。ロック解除を確認し、必要なら「設定 → 一般 → VPNとデバイス管理」でご自身の開発者を信頼・検証してください。アプリは削除しないでください。')
                continue
            pid = result.get('process', {}).get('processIdentifier')
            if not pid:
                raise UpdateError('起動したプロセスを確認できません。')
            time.sleep(2)
            processes = self.device_ctl(['device', 'info', 'processes', '--search', 'PersonalGantt'],
                                        'processes-after').get('runningProcesses', [])
            if not any(x.get('processIdentifier') == pid for x in processes):
                raise UpdateError('起動直後にアプリが終了しました。ログを確認してください。')
            self.state['phase'] = 'complete'
            save(PRIVATE / 'state.json', self.state)
            save(self.run_dir / 'result.json', self.state)
            return
        raise UpdateError('起動確認が完了していません。信頼設定後に --launch-only を実行してください。')


def report(state):
    if not state.get('expires'):
        say('更新記録がありません。通常の更新を実行すると期限が記録されます。')
        return
    expiry = dt.datetime.fromisoformat(state['expires']).astimezone()
    say('署名期限: ' + expiry.strftime('%Y/%m/%d %H:%M %Z'))
    say('次回更新の目安: ' + (expiry - dt.timedelta(days=1)).strftime('%Y/%m/%d'))
    say('状態: ' + {'complete': '更新・データ保持・起動確認済み',
                    'verified-awaiting-launch': 'データ保持確認済み・起動確認待ち',
                    'installed': 'インストール済み・データ照合未完了'}.get(state['phase'], state['phase']))


def main(argv=None):
    parser = argparse.ArgumentParser(description='USB接続したPersonalGanttを再署名・上書き更新します。')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true', help='接続・ロック・既存アプリを確認（更新しない）')
    mode.add_argument('--status', action='store_true', help='最後に記録した署名期限を表示（接続不要）')
    mode.add_argument('--launch-only', action='store_true', help='更新後の信頼設定が済んだら起動だけ再確認')
    parser.add_argument('--device', help='複数接続時の実機識別子（通常は不要）')
    parser.add_argument('--non-interactive', action='store_true', help='入力待ちせず必要な操作を案内して終了')
    args = parser.parse_args(argv)
    os.umask(0o077)
    if args.status:
        path = PRIVATE / 'state.json'
        report(json.loads(path.read_text()) if path.exists() else {})
        return 0
    updater = Updater(args)
    lock = (PRIVATE / 'update.lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        say('別の更新処理が実行中です。終了を待ってください。')
        return 1
    try:
        updater.preflight()
        if args.check:
            say('接続・ロック解除・既存アプリ・保存領域の確認ができました。更新は行っていません。')
            return 0
        if args.launch_only:
            path = PRIVATE / 'state.json'
            previous = json.loads(path.read_text()) if path.exists() else {}
            if (previous.get('phase') not in ('verified-awaiting-launch', 'complete')
                    or previous.get('device', {}).get('udid') != updater.device['udid']):
                raise UpdateError('この端末のデータ照合済み更新記録がありません。通常の更新を実行してください。')
            updater.state = previous
            updater.launch()
        else:
            say('更新中はアプリを終了します。作業タイマーは先に停止してください。')
            app = updater.build()
            updater.install(app)
            updater.launch()
        report(updater.state)
        say('バックアップと実行ログ: ' + str(updater.run_dir))
        return 0
    except (UpdateError, OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        say('停止: ' + str(error))
        say('実行ログ: ' + str(updater.run_dir))
        if updater.state.get('phase') == 'verified-awaiting-launch':
            say('信頼確認後: ./update-iphone.command --launch-only')
        return 1
    except KeyboardInterrupt:
        say('\n中止しました。バックアップとログは保持しています。')
        return 130
    finally:
        if not updater.profile_ready:
            restore_profiles(updater.moved)
        lock.close()


if __name__ == '__main__':
    sys.exit(main())
