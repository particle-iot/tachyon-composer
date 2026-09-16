import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

from package import compare_layout, package, programs
from validate import inside
from flash import verify_bundle


class FlashSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.xml = ET.Element('data')
        for lun, label, start in [(0, 'efi', 6), (0, 'system', 20),
                                  (6, 'dtb_a', 6), (6, 'core_nhlos_a', 20)]:
            self.add(lun, label, start)
        (self.root/'prog_firehose_ddr.elf').write_bytes(b'firehose')

    def add(self, lun, label, start, filename=None):
        filename = filename if filename is not None else label+'.img'
        if filename:
            (self.root/filename).write_bytes(b'x'*4096)
        return ET.SubElement(self.xml, 'program', {
            'physical_partition_number': str(lun), 'label': label,
            'start_sector': str(start), 'num_partition_sectors': '2',
            'SECTOR_SIZE_IN_BYTES': '4096', 'filename': filename, 'sparse': 'false'})

    def write(self):
        ET.ElementTree(self.xml).write(self.root/'rawprogram0.xml')

    def test_archive_removes_gpt_provisioning_and_unreferenced_files(self):
        self.add(0, 'PrimaryGPT', 0, 'gpt_main0.bin')
        self.add(5, 'modemst1', 6, '')
        (self.root/'provision_ufs22.xml').write_text('<data><ufs commit="1"/></data>')
        (self.root/'patch0.xml').write_text('<patches/>')
        (self.root/'rawprogram0_WIPE_PARTITIONS.xml').write_text('<data><erase/></data>')
        self.write()
        config = json.loads((Path(__file__).parents[2]/'versions.json').read_text())
        package(self.root, config, 'NA', '0.1.0-test', 'test-image')
        manifest = json.loads((self.root/'manifest.json').read_text())
        self.assertEqual(manifest['targets'][0]['qcm6490']['edl']['patch_xml'], [])
        self.assertEqual(sorted(p.name for p in self.root.glob('*.xml')), ['rawprogram_qli.xml'])
        self.assertFalse((self.root/'gpt_main0.bin').exists())
        writes = list(ET.parse(self.root/'rawprogram_qli.xml').getroot())
        self.assertEqual({p.get('label') for p in writes}, {'efi','system','dtb_a','core_nhlos_a'})

    def test_final_zip_verifies_and_detects_changed_payload(self):
        self.write()
        report = self.root/'package-validation.json'
        report.write_text(json.dumps({'passed': True, 'hardware_tests': 'not_run'}))
        config = json.loads((Path(__file__).parents[2]/'versions.json').read_text())
        package(self.root, config, 'NA', '0.1.0-test', 'test-image')
        self.assertTrue(report.is_file())
        self.assertIn('package-validation.json', (self.root/'SHA256SUMS').read_text())
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp)/'image.zip'
            def archive():
                with zipfile.ZipFile(image, 'w') as z:
                    for p in self.root.iterdir(): z.write(p, p.name)
            archive()
            manifest, writes = verify_bundle(image)
            self.assertEqual(manifest['region'], 'NA')
            self.assertEqual(len(writes), 4)
            (self.root/'system.img').write_bytes(b'corrupted')
            archive()
            with self.assertRaisesRegex(ValueError, 'Archive hash mismatch'):
                verify_bundle(image)

    def test_changed_validation_report_invalidates_bundle(self):
        self.write()
        report = self.root/'package-validation.json'
        report.write_text(json.dumps({'passed': True, 'hardware_tests': 'not_run'}))
        config = json.loads((Path(__file__).parents[2]/'versions.json').read_text())
        package(self.root, config, 'NA', '0.1.0-test', 'test-image')
        report.write_text(json.dumps({'passed': True, 'hardware_tests': 'passed'}))
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp)/'image.zip'
            with zipfile.ZipFile(image, 'w') as z:
                for p in self.root.iterdir():
                    z.write(p, p.name)
            with self.assertRaisesRegex(ValueError, 'Archive hash mismatch'):
                verify_bundle(image)

    def test_nv_payload_is_rejected(self):
        self.add(5, 'modemst1', 6)
        self.write()
        with self.assertRaisesRegex(ValueError, 'Forbidden write'):
            programs(self.root)

    def test_overlap_is_rejected(self):
        self.xml[1].set('start_sector', '6')
        self.write()
        with self.assertRaisesRegex(ValueError, 'Overlapping'):
            programs(self.root)

    def test_oversize_payload_is_rejected(self):
        (self.root/'system.img').write_bytes(b'x'*8193)
        self.write()
        with self.assertRaisesRegex(ValueError, 'oversize'):
            programs(self.root)

    def test_geometry_must_fit_actual_board(self):
        self.write()
        writes = [r for _,r in programs(self.root)]
        baseline = {'partitions': [dict(r) for r in writes]}
        compare_layout(writes, baseline)
        baseline['partitions'][1]['start_bytes'] += 4096
        with self.assertRaisesRegex(ValueError, 'layout mismatch'):
            compare_layout(writes, baseline)

    def test_board_partition_may_be_larger_but_not_smaller(self):
        self.write()
        writes = [r for _,r in programs(self.root)]
        baseline = {'partitions': [dict(r) for r in writes]}
        baseline['partitions'][1]['size_bytes'] += 4096
        compare_layout(writes, baseline)
        baseline['partitions'][1]['size_bytes'] = 4095
        with self.assertRaises(ValueError):
            compare_layout(writes, baseline)

    def test_absolute_image_symlinks_never_resolve_against_builder(self):
        (self.root/'lib').symlink_to('/usr/lib')
        self.assertEqual(inside(self.root, '/lib/os-release'), self.root/'usr/lib/os-release')
        (self.root/'bad').symlink_to('../../outside')
        with self.assertRaises(ValueError):
            inside(self.root, '/bad')

    def test_growing_system_write_is_bounded_to_actual_image(self):
        self.xml[1].set('num_partition_sectors', '0')
        self.write()
        attrs, row = programs(self.root)[1]
        self.assertEqual(attrs['num_partition_sectors'], '1')
        self.assertEqual(row['size_bytes'], 4096)


if __name__ == '__main__':
    unittest.main()
