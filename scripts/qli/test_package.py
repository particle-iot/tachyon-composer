import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

from package import compare_layout, package, programs
from layout import NV, PROGRAM_XML, PATCH_XML, check_protected
from validate import inside
from flash import verify_bundle


class FlashSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Exercise the real shared Ubuntu/QLI partition generator, not a second
        # hand-written layout that could drift from what actually gets shipped.
        cls.fixture = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.fixture.cleanup)
        cls.source = Path(cls.fixture.name)
        assemble = Path(__file__).resolve().parents[1] / 'assemble'
        config = ET.parse(assemble/'config/partition_ext.xml')
        config.find("./physical_partition/partition[@label='misc']").set('filename', 'misc.img')
        config.write(cls.source/'partition_ext.xml')
        subprocess.run([sys.executable, '-W', 'ignore', str(assemble/'ptool.py'), '-x', 'partition_ext.xml'],
                       cwd=cls.source, stdout=subprocess.DEVNULL, check=True)
        for name in PROGRAM_XML:
            for p in ET.parse(cls.source/name).getroot():
                filename = p.get('filename')
                if filename and not (cls.source/filename).exists():
                    size = 1024*1024 if p.get('label') == 'misc' else 4096
                    (cls.source/filename).write_bytes(bytes(size))
        (cls.source/'prog_firehose_ddr.elf').write_bytes(b'firehose')

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copytree(self.source, self.root, dirs_exist_ok=True)

    def edit_program(self, lun, label, **attrs):
        path = self.root/PROGRAM_XML[lun]
        tree = ET.parse(path)
        p = tree.find(f"./program[@label='{label}']")
        p.attrib.update(attrs)
        tree.write(path)

    def package(self):
        config = json.loads((Path(__file__).parents[2]/'versions.json').read_text())
        package(self.root, config, 'NA', '0.1.0-test', 'test-image')

    def archive(self, path):
        with zipfile.ZipFile(path, 'w') as z:
            for p in self.root.iterdir():
                z.write(p, p.name)

    def baseline(self):
        return {'partitions': [dict(lun=5, label=label, start_bytes=start*4096, size_bytes=count*4096)
                               for label, (start,count) in NV.items()],
                'disks': [dict(lun=lun, sector_size=4096, size_bytes=size) for lun,size in enumerate(
                    [61354278912, 8388608, 8388608, 134217728, 134217728, 150994944, 1879048192])]}

    def test_full_flash_set_retains_declarations_and_removes_provisioning(self):
        (self.root/'provision_ufs22.xml').write_text('<data><ufs commit="1"/></data>')
        self.package()
        manifest = json.loads((self.root/'manifest.json').read_text())
        edl = manifest['targets'][0]['qcm6490']['edl']
        self.assertEqual(edl['program_xml'], PROGRAM_XML)
        self.assertEqual(edl['patch_xml'], PATCH_XML)
        self.assertEqual({p.name for p in self.root.glob('*.xml')}, set(PROGRAM_XML+PATCH_XML))
        self.assertEqual(len(list(self.root.glob('gpt_*.bin'))), 14)
        declarations = [p for name in PROGRAM_XML for p in ET.parse(self.root/name).getroot()]
        self.assertTrue(any(p.get('label') == 'persist' and p.get('filename') == '' for p in declarations))
        writes = [r for _,r in programs(self.root)]
        self.assertEqual(len(writes), 37)  # 22 Ubuntu payloads + misc + 14 GPTs
        compare_layout(writes, self.baseline())

    def test_final_zip_verifies_and_detects_changed_payload(self):
        report = self.root/'package-validation.json'
        report.write_text(json.dumps({'passed': True, 'hardware_tests': 'not_run'}))
        self.package()
        self.assertIn('package-validation.json', (self.root/'SHA256SUMS').read_text())
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp)/'image.zip'
            self.archive(image)
            manifest, writes = verify_bundle(image)
            self.assertEqual(manifest['region'], 'NA')
            self.assertEqual(len(writes), 37)
            (self.root/'system.img').write_bytes(b'corrupted')
            self.archive(image)
            with self.assertRaisesRegex(ValueError, 'Archive hash mismatch'):
                verify_bundle(image)

    def test_changed_validation_report_invalidates_bundle(self):
        report = self.root/'package-validation.json'
        report.write_text(json.dumps({'passed': True, 'hardware_tests': 'not_run'}))
        self.package()
        report.write_text(json.dumps({'passed': True, 'hardware_tests': 'passed'}))
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp)/'image.zip'
            self.archive(image)
            with self.assertRaisesRegex(ValueError, 'Archive hash mismatch'):
                verify_bundle(image)

    def test_misc_is_real_full_size_and_in_target_gpt(self):
        attrs, write = next((a, r) for a, r in programs(self.root) if r['label'] == 'misc')
        self.assertEqual(attrs['start_sector'], '138758')
        self.assertEqual(write['size_bytes'], 1024*1024)
        self.assertEqual((self.root/write['filename']).read_bytes(), bytes(1024*1024))

    def test_missing_misc_payload_is_rejected(self):
        self.edit_program(0, 'misc', filename='')
        with self.assertRaisesRegex(ValueError, 'Missing required partition'):
            programs(self.root)

    def test_short_misc_payload_is_rejected(self):
        (self.root/'misc.img').write_bytes(bytes(4096))
        with self.assertRaisesRegex(ValueError, 'misc payload must cover'):
            programs(self.root)

    def test_nv_payload_is_rejected(self):
        self.edit_program(5, 'modemst1', filename='nv.img')
        with self.assertRaisesRegex(ValueError, 'Forbidden write'):
            programs(self.root)

    def test_missing_ubuntu_firmware_target_is_rejected(self):
        self.edit_program(6, 'qupfw_a', filename='')
        with self.assertRaisesRegex(ValueError, 'Incomplete Ubuntu-compatible'):
            programs(self.root)

    def test_rebuilt_gpt_cannot_move_fixed_nv(self):
        config = ET.parse(self.root/'partition_ext.xml')
        config.find(".//partition[@label='fsc']").set('size_in_kb', '256')
        config.write(self.root/'partition_ext.xml')
        tool = Path(__file__).resolve().parents[1]/'assemble/ptool.py'
        subprocess.run([sys.executable, '-W', 'ignore', str(tool), '-x', 'partition_ext.xml'],
                       cwd=self.root, stdout=subprocess.DEVNULL, check=True)
        with self.assertRaisesRegex(ValueError, 'Fixed provisioning geometry changed'):
            programs(self.root)

    def test_write_must_match_target_gpt(self):
        self.edit_program(0, 'system', start_sector='6')
        with self.assertRaisesRegex(ValueError, 'target GPT disagree'):
            programs(self.root)

    def test_oversize_payload_is_rejected(self):
        self.edit_program(6, 'multiimgoem_a', filename='oversize.img')
        (self.root/'oversize.img').write_bytes(bytes(32769))
        with self.assertRaisesRegex(ValueError, 'oversize'):
            programs(self.root)

    def test_different_installed_os_layout_is_allowed(self):
        writes = [r for _,r in programs(self.root)]
        baseline = self.baseline()
        baseline['partitions'].extend([dict(lun=0,label='misc',start_bytes=392*4096,size_bytes=256*4096),
                                      dict(lun=5,label='persist',start_bytes=3904*4096,size_bytes=8192*4096)])
        compare_layout(writes, baseline)

    def test_physical_capacity_and_provisioning_are_required(self):
        writes = [r for _,r in programs(self.root)]
        baseline = self.baseline()
        baseline['disks'][0]['size_bytes'] = 512*1024*1024
        with self.assertRaisesRegex(ValueError, 'physical LUN|backup GPT'):
            compare_layout(writes, baseline)
        baseline = self.baseline()
        baseline['partitions'][0]['start_bytes'] += 4096
        with self.assertRaisesRegex(ValueError, 'provisioning geometry'):
            compare_layout(writes, baseline)
        baseline = self.baseline()
        del baseline['disks']
        with self.assertRaisesRegex(ValueError, 'capacities'):
            compare_layout(writes, baseline)

    def test_missing_gpt_or_patch_fails(self):
        for name in ['gpt_main0.bin', 'gpt_backup5.bin', 'patch4.xml']:
            with self.subTest(name=name):
                contents = (self.root/name).read_bytes()
                (self.root/name).unlink()
                with self.assertRaises(FileNotFoundError):
                    programs(self.root)
                (self.root/name).write_bytes(contents)

    def test_patch_cannot_overwrite_provisioning_or_change_nv_gpt_entry(self):
        path = self.root/'patch5.xml'
        original = path.read_bytes()
        for attrs in [dict(start_sector='1088'), dict(byte_offset='168')]:
            path.write_bytes(original)
            tree = ET.parse(path)
            tree.getroot()[1].attrib.update(attrs)
            tree.write(path)
            with self.assertRaisesRegex(ValueError, 'Unexpected GPT sizing'):
                programs(self.root)

    def test_gpt_crc_damage_is_rejected(self):
        path = self.root/'gpt_main5.bin'
        content = bytearray(path.read_bytes()); content[8200] ^= 1
        path.write_bytes(content)
        with self.assertRaisesRegex(ValueError, 'GPT partition CRC'):
            programs(self.root)

    def test_legacy_persist_and_uefi_data_are_protected(self):
        for lun,start,count in [(5,3904,8192),(4,518,128),(0,131078,7680)]:
            with self.assertRaisesRegex(ValueError, 'protected data'):
                check_protected(lun,start,count)

    def test_absolute_image_symlinks_never_resolve_against_builder(self):
        (self.root/'lib').symlink_to('/usr/lib')
        self.assertEqual(inside(self.root, '/lib/os-release'), self.root/'usr/lib/os-release')
        (self.root/'bad').symlink_to('../../outside')
        with self.assertRaises(ValueError):
            inside(self.root, '/bad')

    def test_growing_system_xml_is_retained_but_sidecar_records_actual_write(self):
        attrs, row = next((a,r) for a,r in programs(self.root) if r['label'] == 'system')
        self.assertEqual(attrs['num_partition_sectors'], '0')
        self.assertEqual(row['size_bytes'], 4096)


if __name__ == '__main__':
    unittest.main()
