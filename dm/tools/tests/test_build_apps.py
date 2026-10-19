"""Shared build orchestration, platform selection and partial-failure recovery.

Compiler/extractor calls use synthetic fixtures; no game files or signing needed.
"""
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts'))
sys.path.insert(0, str(REPO / 'dm/games'))
sys.path.insert(0, str(REPO / 'dm/macos/tools'))
import build_apps_from_nsp as build
import game
import package_app


class SharedBuildTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='nxnative-build-flow-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.nsp_dir = self.root / "玩家's game"; self.nsp_dir.mkdir()
        self.g = game.load('010015100B514000')
        self.chain = re.search(r'#define DMSH_CHAIN "([^"]+)"', self.g.table('dmsh_chain.h').read_text()).group(1)
        (self.nsp_dir / f'Base [{self.g.id}][v0].nsp').write_bytes(b'synthetic fixture')
        (self.nsp_dir / 'Update [010015100B514800][v327680].nsp').write_bytes(b'synthetic fixture')
        self.keys = self.root / 'fixture.keys'; self.keys.write_text('# no key values\n')
        self.work = self.nsp_dir / f'{self.g.id}_build'
        self.events = []
        self.fail_target = None
        self.mocks = {}

        def mock_extract(nx, keys, ex, ver, *rest):
            self.events.append('extract:' + ver)
            out = ex / ver
            (out / 'ExeFS').mkdir(parents=True, exist_ok=True)
            (out / 'RomFS').mkdir(exist_ok=True)
            (out / 'RomFS/payload').write_text('synthetic resource')
            (out / 'ExeFS/main').write_bytes(b'synthetic module')
            (out / 'icon.jpg').write_bytes(b'synthetic icon')
            return out

        def mock_run(cmd, log, env=None, cwd=None, on_line=None):
            Path(log).parent.mkdir(parents=True, exist_ok=True)
            Path(log).write_text('synthetic command output\n')
            if Path(cmd[1]).name in ('dmsh_chain.py', 'c1_guard.py'):
                pass
            elif Path(cmd[1]).name == 'dmsh_build.py':
                self.events.append('shaders')
                self.assertEqual(Path(env['MAIN']), self.work / 'extract' / self.g.get('package') / 'ExeFS/main')
                if self.fail_target == 'shaders': raise build.nsp.BuildError('synthetic shader failure')
                for dest in [Path(cmd[3])] + ([Path(env['IOSOUT'])] if env.get('IOSOUT') else []):
                    lib = dest / f'b-{self.chain}' / 'fixture_b.metallib'
                    lib.parent.mkdir(parents=True, exist_ok=True); lib.write_bytes(b'synthetic shader')
            elif cmd[0] == 'bash':
                self.events.append('ios')
                self.assertTrue((self.work / 'extract').is_dir())
                self.assertTrue((self.work / 'tmp').is_dir())
                if self.fail_target == 'ios': raise build.nsp.BuildError('synthetic iOS failure')
                Path(cmd[-1]).write_bytes(b'synthetic IPA')
            else: self.fail(f'Unexpected subprocess: {cmd}')

        def mock_mac(repo, work, out, *rest):
            self.events.append('macos')
            self.assertTrue((work / 'extract').is_dir())
            self.assertTrue((work / 'tmp').is_dir())
            if self.fail_target == 'macos': raise package_app.PackageError('synthetic Mac failure')
            out.mkdir(parents=True); (out / 'fixture').write_text('synthetic app')
            return '26.0'

        patches = [
            ('build_nx_extract', {'return_value': self.root / 'nx_extract'}),
            ('extract', {'side_effect': mock_extract}),
            ('extract_aoc', {'return_value': None}),
            ('rewrite', {}), ('split_shaders', {}), ('run', {'side_effect': mock_run}),
            ('can_clone', {'return_value': False}), ('free_gb', {'return_value': 1000}),
            ('check_prereqs', {}), ('say', {})]
        for name, opts in patches:
            p = patch.object(build.nsp, name, **opts)
            self.mocks[name] = p.start(); self.addCleanup(p.stop)
        p = patch.object(build.mac, 'check_prereqs'); self.mac_check = p.start(); self.addCleanup(p.stop)
        p = patch.object(package_app, 'build_app', side_effect=mock_mac)
        self.mac_pack = p.start(); self.addCleanup(p.stop)
        p = patch.dict(os.environ, {'IOSOUT': '/must-not-be-inherited'})
        p.start(); self.addCleanup(p.stop)

    def args(self, *options):
        return build.parse_args([str(self.nsp_dir), '-k', str(self.keys), '--app-name', 'Fixture', *options])

    def shader_calls(self):
        return [c for c in self.mocks['run'].call_args_list if Path(c.args[0][1]).name == 'dmsh_build.py']

    def test_both_processes_shared_inputs_once_and_cleans_only_after_packaging(self):
        app = self.root / 'custom/Mario.app'; ipa = self.root / 'custom/Mario.ipa'
        build.main(self.args('--out-app', str(app), '--out-ipa', str(ipa)))
        self.mocks['build_nx_extract'].assert_called_once()
        self.assertEqual(self.mocks['extract'].call_count, 2)  # two versions, shared by both targets
        self.mocks['rewrite'].assert_called_once()
        self.mocks['split_shaders'].assert_called_once()
        self.mocks['extract_aoc'].assert_called_once()
        shaders = self.shader_calls(); self.assertEqual(len(shaders), 1)
        self.assertEqual(shaders[0].kwargs['env']['IOSOUT'], str(self.work / 'shader/ios'))
        self.assertEqual(self.events[-3:], ['shaders', 'macos', 'ios'])
        mac_args = self.mac_pack.call_args.args
        ios_env = self.mocks['run'].call_args.kwargs['env']
        self.assertEqual(str(mac_args[4]), ios_env['PATCHED'])
        self.assertEqual(str(mac_args[5]), ios_env['ROMFS'])
        self.assertTrue(app.is_dir()); self.assertTrue(ipa.is_file())
        self.assertFalse((self.work / 'extract').exists())
        self.assertFalse((self.work / 'tmp').exists())

    def test_macos_only_needs_no_ios_tools_and_does_not_compile_ios_shaders(self):
        build.main(self.args('--target', 'macos'))
        self.mac_check.assert_called_once(); self.mocks['check_prereqs'].assert_not_called()
        self.assertNotIn('IOSOUT', self.shader_calls()[0].kwargs['env'])
        self.assertNotIn('ios', self.events)
        tools = [Path(c.args[0][1]).name for c in self.mocks['run'].call_args_list]
        self.assertLess(tools.index('dmsh_chain.py'), tools.index('dmsh_build.py'))
        self.assertLess(tools.index('dmsh_build.py'), tools.index('c1_guard.py'))

    def test_ios_only_needs_no_mac_app_tools(self):
        build.main(self.args('--target', 'ios'))
        self.mac_check.assert_not_called(); self.mac_pack.assert_not_called()
        self.mocks['check_prereqs'].assert_called_once()
        self.assertEqual(len(self.shader_calls()), 1)
        self.assertNotIn('macos', self.events)

    def test_mac_failure_still_builds_ipa_and_retains_shared_inputs(self):
        self.fail_target = 'macos'
        with self.assertRaisesRegex(build.nsp.BuildError, 'synthetic Mac failure'):
            build.main(self.args())
        self.assertEqual(self.events[-2:], ['macos', 'ios'])
        self.assertTrue((self.nsp_dir / self.g.get('ipa')).is_file())
        self.assertTrue((self.work / 'extract/v0/RomFS/payload').is_file())
        self.assertTrue((self.work / 'tmp').is_dir())

    def test_ios_failure_keeps_finished_mac_app_and_returns_failure(self):
        self.fail_target = 'ios'
        self.assertEqual(build.cli([str(self.nsp_dir), '-k', str(self.keys), '--app-name', 'Fixture']), 1)
        self.assertTrue((self.nsp_dir / Path(self.g.get('ipa')).with_suffix('.app')).is_dir())
        self.assertTrue((self.work / 'extract').is_dir())
        self.assertTrue((self.work / 'tmp').is_dir())

    def test_keep_extracted_applies_after_all_targets_succeed(self):
        build.main(self.args('--keep-extracted'))
        self.assertTrue((self.work / 'extract').is_dir())
        self.assertFalse((self.work / 'tmp').exists())

    def test_shared_shader_failure_retains_inputs_without_packaging(self):
        self.fail_target = 'shaders'
        with self.assertRaisesRegex(build.nsp.BuildError, 'synthetic shader failure'):
            build.main(self.args())
        self.assertTrue((self.work / 'extract').is_dir())
        self.assertTrue((self.work / 'tmp').is_dir())
        self.mac_pack.assert_not_called()
        self.assertNotIn('ios', self.events)

    def test_spyder_settings_and_command_line_override(self):
        with patch.multiple(build, TARGET='macos', NSP_DIR='settings-folder', OUT_DIR='settings-output'):
            args = build.parse_args([])
            self.assertEqual((args.target, args.nsp_dir, args.out_dir), ('macos', 'settings-folder', 'settings-output'))
            args = build.parse_args(['cli-folder', '--target', 'ios', '-o', 'cli-output'])
            self.assertEqual((args.target, args.nsp_dir, args.out_dir), ('ios', 'cli-folder', 'cli-output'))

    def test_unknown_game_is_surveyed_without_platform_prerequisites(self):
        with patch.object(game, 'by_title', return_value=None), \
             patch.object(build.nsp, '_importable', return_value=True), \
             patch.object(build.shutil, 'which', return_value='/fixture/dotnet'), \
             patch.object(build.nsp, 'survey') as survey:
            build.main(self.args())
        survey.assert_called_once()
        self.mac_check.assert_not_called(); self.mocks['check_prereqs'].assert_not_called()
        self.mocks['build_nx_extract'].assert_not_called()


if __name__ == '__main__': unittest.main()
