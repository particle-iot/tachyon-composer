import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('record_runtime', Path(__file__).with_name('record-runtime-rpms.py'))
record = importlib.util.module_from_spec(spec)
spec.loader.exec_module(record)


class RuntimeProvenanceTests(unittest.TestCase):
    def test_refuses_sdk_workspace_even_if_runtime_marker_is_present(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'versions.json'
            config.write_text('{}')
            (root / '.particle-sdk-workspace').touch()
            (root / '.particle-runtime-workspace').touch()
            with self.assertRaisesRegex(ValueError, 'stock runtime'):
                record.collect(config, root, root / 'bundle')

    def test_refuses_unmarked_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'versions.json'
            config.write_text('{}')
            with self.assertRaisesRegex(ValueError, 'stock runtime'):
                record.collect(config, root, root / 'bundle')
