from pathlib import Path
import struct
import tempfile
import unittest

from timezone_data import REQUIRED_ZONES, verify_timezone_data


class TimezoneDataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / 'usr/share/zoneinfo'
        # Minimal valid TZif v1 with one constant UTC offset, independent of
        # the developer machine's installed timezone database.
        tzif = b'TZif\0' + bytes(15) + struct.pack('>6I', 0, 0, 0, 0, 1, 4)
        tzif += struct.pack('>iBB', 0, 0, 0) + b'UTC\0'
        for zone in REQUIRED_ZONES | {'Asia/Kathmandu'}:
            path = self.directory / zone
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(tzif)
        for name in ('zone.tab', 'zone1970.tab'):
            (self.directory / name).write_text('# countries coordinates zone\nNP +2743+08519 Asia/Kathmandu\n')

    def test_complete_database(self):
        self.assertEqual(verify_timezone_data(self.root), len(REQUIRED_ZONES) + 1)

    def test_rejects_missing_database(self):
        with self.assertRaises(OSError):
            verify_timezone_data(self.root / 'empty-image')

    def test_rejects_missing_denver_regression(self):
        (self.directory / 'America/Denver').unlink()
        with self.assertRaisesRegex(ValueError, 'America/Denver'):
            verify_timezone_data(self.root)

    def test_checks_every_advertised_zone(self):
        (self.directory / 'Asia/Kathmandu').unlink()
        with self.assertRaisesRegex(ValueError, 'Asia/Kathmandu'):
            verify_timezone_data(self.root)

    def test_rejects_corrupt_timezone(self):
        (self.directory / 'America/Denver').write_bytes(b'not a timezone')
        with self.assertRaisesRegex(ValueError, 'America/Denver'):
            verify_timezone_data(self.root)

    def test_rejects_empty_table(self):
        (self.directory / 'zone1970.tab').write_text('# no zones\n')
        with self.assertRaisesRegex(ValueError, 'Empty or invalid'):
            verify_timezone_data(self.root)

    def test_rejects_zone_outside_root(self):
        (self.directory / 'zone.tab').write_text('XX +0000 ../../../../outside\n')
        with self.assertRaisesRegex(ValueError, 'escapes'):
            verify_timezone_data(self.root)
