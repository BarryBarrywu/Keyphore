"""Run a copied script with fake macOS process/signing tools; never touch live services."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
IDENTITY = 'Apple Development: Local Developer (CERTIFICATE)'


@unittest.skipUnless(sys.platform == 'darwin', 'requires macOS zsh and bundle copy tools')
class DevelopmentAppTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='.keyphore-test-', dir=Path.home())
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'home'
        self.destination = self.home / 'Applications/Keyphore.app'
        self.destination.mkdir(parents=True)
        (self.destination / 'previous').write_text('preserve me')
        self.system_app = self.root / 'system/Applications/Keyphore.app'
        self.system_app.parent.mkdir(parents=True)
        self.source = self.root / 'source/Keyphore.app'
        companion = self.source / 'Contents/Library/LoginItems/Keyphore Companion.app'
        for executable in [self.source / 'Contents/Helpers/keyphore',
                           companion / 'Contents/MacOS/Keyphore Companion']:
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text('fixture')
            executable.chmod(0o755)
        icon = companion / 'Contents/Resources/AppIcon.icns'
        icon.parent.mkdir(parents=True)
        icon.touch()
        for app, identifier in [(self.source, 'com.barrywu.keyphore'),
                                (companion, 'com.barrywu.keyphore.companion')]:
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
                CFBundleIdentifier=identifier, CFBundleDisplayName='Keyphore',
                CFBundleIconFile='AppIcon')))
        self.commands = self.root / 'commands'
        self.fake = self.root / 'fake'
        self.fake.write_text('''#!''' + sys.executable + '''
import os
from pathlib import Path
import sys
import subprocess
name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ['TEST_ROOT'])
with (root / 'commands').open('a') as log:
    log.write(name + ' ' + ' '.join(args) + '\\n')
if name == 'codesign':
    if '--verify' in args:
        sys.exit(int(os.environ.get('INVALID_SIGNATURE', '0')))
    is_helper = args[-1].endswith('/Helpers/keyphore')
    team = os.environ.get('HELPER_TEAM' if is_helper else 'APP_TEAM', 'LOCALTEAM1')
    if '/system/Applications/' in args[-1]:
        team = os.environ.get('SYSTEM_TEAM', team)
    authority = os.environ.get('HELPER_IDENTITY' if is_helper else 'APP_IDENTITY',
                               os.environ['KEYPHORE_SIGNING_IDENTITY'])
    print('TeamIdentifier=' + team)
    print('Authority=' + authority)
elif name == 'pgrep':
    running = 'Contents/MacOS/Keyphore$' in args[-1] and (root / 'running').exists()
    orphan = ' companion' in args[-1] and os.environ.get('ORPHAN') == '1'
    sys.exit(0 if running or orphan else 1)
elif name == 'osascript':
    if os.environ.get('REFUSE_QUIT') != '1':
        terminated_all = os.environ.get('MULTIPLE_APPS') != '1'
        if not terminated_all and args[:2] == ['-l', 'JavaScript']:
            # Execute the real JXA loop against two mock NSRunningApplications, never live Apps.
            mock = "function run() { const terminated = []; const $ = {NSRunningApplication: {runningApplicationsWithBundleIdentifier: function() { return {count: 2, objectAtIndex: function(index) { return {get terminate() { terminated.push(index); return true; }}; }}; }}}; " + args[-1] + '; return JSON.stringify(terminated); }'
            result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', mock],
                                    capture_output=True, text=True)
            terminated_all = result.returncode == 0 and result.stdout.strip() == '[0,1]'
        if terminated_all:
            (root / 'running').unlink(missing_ok=True)
elif name == 'launchctl':
    sys.exit(0 if os.environ.get('LOADED') == '1' or args[0] == 'bootout' else 1)
elif name == 'ln':
    if os.environ.get('FAIL_REDIRECT') == '1':
        sys.exit(1)
    os.execv('/bin/ln', ['/bin/ln'] + args)
elif name == 'xcodebuild':
    sys.exit(1)
elif name == 'mv':
    if os.environ.get('FAIL_INSTALL') == '1' and '/.Keyphore.' in args[0]:
        sys.exit(1)
    os.execv('/bin/mv', ['/bin/mv'] + args)
''')
        self.fake.chmod(0o755)
        script = (ROOT / 'tools/keyphore-development-app').read_text()
        for name, original in [('codesign', '/usr/bin/codesign'), ('pgrep', '/usr/bin/pgrep'),
                               ('osascript', '/usr/bin/osascript'), ('sleep', '/bin/sleep'),
                               ('mv', '/bin/mv'), ('ln', '/bin/ln'), ('xcodebuild', '/usr/bin/xcodebuild')]:
            replacement = self.root / name
            replacement.symlink_to(self.fake)
            script = script.replace(original, str(replacement))
        for name in ['launchctl', 'open']:
            (self.root / name).symlink_to(self.fake)
        script = script.replace('/private/tmp/codex-builds', str(self.root / 'builds'))
        script = script.replace('system_destination=/Applications/Keyphore.app',
                                'system_destination=' + str(self.system_app))
        self.script = self.root / 'development-app'
        self.script.write_text(script)
        self.env = dict(os.environ, HOME=str(self.home), TEST_ROOT=str(self.root),
                        KEYPHORE_LAUNCHCTL_BIN=str(self.root / 'launchctl'),
                        KEYPHORE_OPEN_BIN=str(self.root / 'open'),
                        KEYPHORE_DEVELOPMENT_TEAM='LOCALTEAM1', KEYPHORE_SIGNING_IDENTITY=IDENTITY)

    def run_script(self, command, **env):
        args = ['/bin/zsh', str(self.script), command]
        if command in ('verify', 'install'):
            args.append(str(self.source))
        return subprocess.run(args, env=dict(self.env, **env), capture_output=True, text=True)

    def test_explicit_local_identity_requires_matching_valid_signatures(self):
        self.assertEqual(self.run_script('verify').returncode, 0)
        for change in [dict(HELPER_TEAM='OTHERTEAM'), dict(HELPER_IDENTITY='Apple Development: Other'),
                       dict(KEYPHORE_SIGNING_IDENTITY='-'), dict(INVALID_SIGNATURE='1'),
                       dict(KEYPHORE_SIGNING_IDENTITY='Developer ID Application', APP_IDENTITY=IDENTITY)]:
            with self.subTest(change=change):
                self.assertNotEqual(self.run_script('verify', **change).returncode, 0)

    def test_failed_quit_preserves_app_and_does_not_stop_companion(self):
        (self.root / 'running').touch()
        result = self.run_script('install', REFUSE_QUIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.destination / 'previous').exists())
        commands = self.commands.read_text()
        self.assertIn('osascript ', commands)
        self.assertNotIn('launchctl bootout', commands)
        self.assertNotIn('open ', commands)

    def test_all_running_app_instances_receive_normal_quit(self):
        (self.root / 'running').touch()
        result = self.run_script('install', MULTIPLE_APPS='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('open ' + str(self.destination), self.commands.read_text())

    def test_surviving_companion_blocks_install(self):
        for change in [dict(LOADED='1'), dict(ORPHAN='1')]:
            with self.subTest(change=change):
                self.assertNotEqual(self.run_script('install', **change).returncode, 0)
                self.assertTrue((self.destination / 'previous').exists())
        self.assertNotIn('open ', self.commands.read_text())

    def test_safe_quit_installs_at_stable_path_and_preserves_backup(self):
        (self.root / 'running').touch()
        result = self.run_script('install')
        self.assertEqual(result.returncode, 0, result.stderr)
        backups = list((self.home / '.Trash').glob('Keyphore.previous.*/Keyphore.app/previous'))
        self.assertEqual(len(backups), 1)
        self.assertTrue((self.destination / 'Contents/Info.plist').exists())
        self.assertIn('open ' + str(self.destination), self.commands.read_text())

    def test_explicit_system_redirect_backs_up_old_app_and_is_idempotent(self):
        shutil.copytree(self.source, self.system_app)
        (self.system_app / 'old-system').touch()
        result = self.run_script('install', KEYPHORE_REDIRECT_SYSTEM_APP='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.system_app.readlink(), self.destination)
        backups = list((self.home / '.Trash').glob('*/Keyphore.system.app/old-system'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.run_script('install', KEYPHORE_REDIRECT_SYSTEM_APP='1').returncode, 0)
        self.assertEqual(self.system_app.readlink(), self.destination)

    def test_system_redirect_rejects_unknown_symlink_and_bundle_before_quit(self):
        self.system_app.symlink_to(self.source)
        result = self.run_script('install', KEYPHORE_REDIRECT_SYSTEM_APP='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.system_app.readlink(), self.source)
        self.system_app.unlink()
        shutil.copytree(self.source, self.system_app)
        (self.system_app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='unknown')))
        self.assertNotEqual(self.run_script('install', KEYPHORE_REDIRECT_SYSTEM_APP='1').returncode, 0)
        self.assertNotIn('launchctl ', self.commands.read_text())
        self.assertTrue((self.destination / 'previous').exists())

    def test_system_redirect_rejects_other_signing_team_before_quit(self):
        shutil.copytree(self.source, self.system_app)
        result = self.run_script('install', KEYPHORE_REDIRECT_SYSTEM_APP='1', SYSTEM_TEAM='OTHERTEAM')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.system_app.is_symlink())
        self.assertNotIn('launchctl ', self.commands.read_text())
        self.assertTrue((self.destination / 'previous').exists())

    def test_failed_redirect_restores_both_app_paths(self):
        shutil.copytree(self.source, self.system_app)
        (self.system_app / 'old-system').touch()
        result = self.run_script('install', KEYPHORE_REDIRECT_SYSTEM_APP='1', FAIL_REDIRECT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.destination / 'previous').exists())
        self.assertFalse(self.system_app.is_symlink())
        self.assertTrue((self.system_app / 'old-system').exists())
        self.assertNotIn('open ', self.commands.read_text())

    def test_failed_build_passes_explicit_signing_and_cleans_temporary_directory(self):
        result = self.run_script('build-open')
        self.assertNotEqual(result.returncode, 0)
        commands = self.commands.read_text()
        self.assertIn('DEVELOPMENT_TEAM=LOCALTEAM1', commands)
        self.assertIn('CODE_SIGN_IDENTITY=' + IDENTITY, commands)
        self.assertEqual(list((self.root / 'builds').iterdir()), [])
        self.assertNotIn('osascript ', commands)

    def test_failed_install_restores_previous_app(self):
        result = self.run_script('install', FAIL_INSTALL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.destination / 'previous').exists())
        self.assertNotIn('open ', self.commands.read_text())


if __name__ == '__main__':
    unittest.main()
