import base64
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('release_channel', str(ROOT / 'tools/keyphore-release'))
spec = importlib.util.spec_from_loader(loader.name, loader)
release = importlib.util.module_from_spec(spec)
loader.exec_module(release)


class ReleaseChannelTests(unittest.TestCase):
    def test_dmg_shows_only_app_and_applications_shortcut(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'Keyphore.app'
            notices = app / 'Contents/Resources/Licenses'
            notices.mkdir(parents=True)
            (notices / 'LICENSE').write_text('license preserved inside app')
            staging = root / 'contents'
            release.prepare_dmg_contents(app, staging)
            self.assertEqual({p.name for p in staging.iterdir() if not p.name.startswith('.')},
                             {'Keyphore.app', 'Applications'})
            self.assertEqual((staging / 'Applications').readlink(), Path('/Applications'))
            self.assertTrue((staging / '.DS_Store').is_file())
            self.assertEqual((staging / 'Keyphore.app/Contents/Resources/Licenses/LICENSE').read_text(),
                             'license preserved inside app')

    def manifest(self):
        return dict(version='0.2.0', build='2', hook_digest='a' * 64,
                    source_commit='b' * 40, source_status='',
                    feed_url='https://raw.githubusercontent.com/BarryBarrywu/Keyphore/main/updates/appcast.xml',
                    download_url=release.release_download_url('0.2.0'),
                    public_key=base64.b64encode(bytes(range(32))).decode())

    def test_separate_github_metadata_and_asset_hosts_are_allowed(self):
        release.require_production_channel(self.manifest())

    def test_insecure_urls_and_credentials_are_rejected(self):
        for url in ['http://github.com/a', 'https://token@github.com/a',
                    'https://github.com/a?token=secret', 'https://github.com/a#fragment',
                    'https://github.com/a b']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                release.https_url(url)

    def test_both_production_endpoints_reject_placeholder_hosts(self):
        for field in ['feed_url', 'download_url']:
            for host in ['example.invalid', 'example.com', 'localhost']:
                manifest = self.manifest()
                manifest[field] = 'https://' + host + '/file'
                with self.subTest(field=field, host=host), self.assertRaises(ValueError):
                    release.require_production_channel(manifest)

    def test_invalid_and_zero_keys_are_rejected(self):
        for key in [bytes(32), b'short']:
            manifest = self.manifest()
            manifest['public_key'] = base64.b64encode(key).decode()
            with self.assertRaises(ValueError):
                release.require_production_channel(manifest)

    def prepare(self, root):
        (root / 'updates').mkdir()
        (root / 'LICENSES').mkdir()
        (root / 'LICENSES/NUPHYIO-NOTICE.txt').write_text('third-party notice')
        (root / 'LICENSE').write_text('project license')
        (root / 'updates/appcast.xml').write_text(
            '<rss xmlns:sparkle="' + release.SPARKLE + '"><channel><title>Keyphore</title>'
            '<item><sparkle:version>1</sparkle:version>'
            '<sparkle:shortVersionString>0.1.0</sparkle:shortVersionString></item>'
            '</channel></rss>')
        en, zh = root / 'en.txt', root / 'zh.txt'
        en.write_text('Fix <update> & preserve settings.')
        zh.write_text('修复更新，并保留设置。')
        dmg = root / 'Keyphore-0.2.0.dmg'
        dmg.write_bytes(b'test archive, not an installable app')
        return SimpleNamespace(sparkle_account='test', notes_en=en, notes_zh_hans=zh), dmg

    def fake_run(self, *args):
        if str(args[0]) == 'git':
            destination = next(str(arg)[9:] for arg in args if str(arg).startswith('--output='))
            Path(destination).write_bytes(b'test source archive')
        return 'test-signature'

    def test_signed_channel_preserves_history_localizes_notes_and_separates_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args, dmg = self.prepare(root)
            with patch.object(release, 'ROOT', root), patch.object(release, 'run', side_effect=self.fake_run) as run:
                release.write_channel(args, self.manifest(), root / 'public', dmg, root / 'bin')
            feed = root / 'public/updates/appcast.xml'
            items = ET.parse(feed).getroot().findall('channel/item')
            self.assertEqual(len(items), 2)
            item = items[0]
            self.assertEqual(item.find('enclosure').get('url'), self.manifest()['download_url'])
            notes = item.findall('description')
            self.assertEqual([n.get('{http://www.w3.org/XML/1998/namespace}lang') for n in notes], ['en', 'zh-Hans'])
            self.assertEqual(notes[0].text, args.notes_en.read_text())
            self.assertEqual(notes[1].text, args.notes_zh_hans.read_text())
            self.assertTrue((root / 'public/release-assets/Keyphore-0.2.0-source.zip').is_file())
            self.assertFalse((root / 'public/updates/Keyphore-0.2.0.dmg').exists())
            calls = [c.args for c in run.call_args_list]
            self.assertIn((root / 'bin/sign_update', '--account', 'test', '--verify', root / 'updates/appcast.xml'), calls)
            self.assertEqual(calls[-2:], [(root / 'bin/sign_update', '--account', 'test', feed),
                                         (root / 'bin/sign_update', '--account', 'test', '--verify', feed)])

    def test_build_regression_or_reused_release_version_is_rejected(self):
        for field, value in [('build', '1'), ('version', '0.1.0')]:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                args, dmg = self.prepare(root)
                manifest = self.manifest()
                manifest[field] = value
                with patch.object(release, 'ROOT', root), patch.object(release, 'run', side_effect=self.fake_run):
                    with self.assertRaises(ValueError):
                        release.write_channel(args, manifest, root / 'public', dmg, root / 'bin')

    def test_dirty_source_cannot_be_staged_as_corresponding_source(self):
        manifest = self.manifest()
        manifest['source_status'] = ' M runtime/Sources/main.swift'
        with self.assertRaisesRegex(ValueError, 'source must be committed'):
            release.stage(SimpleNamespace(), manifest)

    def test_xcode_configuration_contains_production_url_and_real_public_key(self):
        config = release.channel_configuration()
        manifest = self.manifest()
        manifest['feed_url'] = config['KEYPHORE_UPDATE_FEED_URL']
        manifest['public_key'] = config['KEYPHORE_UPDATE_PUBLIC_ED_KEY']
        release.require_production_channel(manifest)
        self.assertNotIn('$()', manifest['feed_url'])


if __name__ == '__main__':
    unittest.main()
