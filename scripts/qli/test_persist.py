import runpy
from pathlib import Path
import subprocess
import tempfile
import unittest

prepare = runpy.run_path(str(Path(__file__).with_name('tachyon-prepare-persist')))['prepare']


class PersistTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.disk = self.root/'devices/sda'
        self.info = self.disk/'sda2'
        self.info.mkdir(parents=True)
        (self.info/'start').write_text(str(131078*8))
        (self.info/'size').write_text(str(7680*8))
        (self.root/'0:0:0:0').mkdir()
        (self.disk/'device').symlink_to(self.root/'0:0:0:0')
        self.sys = self.root/'sys'; self.sys.mkdir()
        (self.sys/'sda2').symlink_to(self.info)
        self.device = self.root/'sda2'; self.device.touch()
        self.calls = []
        self.probe = (2, '')

    def command(self, args, **kwargs):
        self.calls.append(args)
        code, output = self.probe if args[0] == 'blkid' else (0, '4096\n')
        return subprocess.CompletedProcess(args, code, output)

    def invoke(self):
        prepare(self.device, self.sys, self.command)

    def test_empty_os_extent_is_initialized(self):
        self.invoke()
        self.assertEqual(self.calls[-1], ['mkfs.ext4', '-F', str(self.device.resolve())])

    def test_existing_ext4_is_never_formatted(self):
        self.probe = (0, 'ext4\n')
        self.invoke()
        self.assertFalse(any(c[0] == 'mkfs.ext4' for c in self.calls))

    def test_blank_gpt_partition_ignores_partition_entry_metadata(self):
        def with_gpt_metadata(args, **kwargs):
            if args[0] == 'blkid':
                # Real blkid returns 0 with no TYPE when only PART_ENTRY_*
                # metadata exists; -D makes the blank partition return 2.
                self.probe = (2 if '-D' in args else 0, '')
            return self.command(args, **kwargs)

        prepare(self.device, self.sys, with_gpt_metadata)
        self.assertEqual(self.calls[-1], ['mkfs.ext4', '-F', str(self.device.resolve())])

    def test_unknown_or_ambiguous_filesystems_fail_without_formatting(self):
        for self.probe in [(0, 'xfs\n'), (0, ''), (8, ''), (4, ''), (2, 'ext4')]:
            with self.assertRaisesRegex(RuntimeError, 'refusing to format'):
                self.invoke()
        self.assertFalse(any(c[0] == 'mkfs.ext4' for c in self.calls))

    def test_legacy_or_shifted_partition_is_never_formatted(self):
        (self.info/'start').write_text(str(3904*8))
        with self.assertRaisesRegex(RuntimeError, 'outside the QLI OS extent'):
            self.invoke()
        self.assertEqual(self.calls, [])

    def test_same_extent_on_another_lun_is_rejected(self):
        (self.disk/'device').unlink()
        (self.root/'0:0:0:5').mkdir()
        (self.disk/'device').symlink_to(self.root/'0:0:0:5')
        with self.assertRaisesRegex(RuntimeError, 'outside UFS LUN 0'):
            self.invoke()
        self.assertEqual(self.calls, [])
