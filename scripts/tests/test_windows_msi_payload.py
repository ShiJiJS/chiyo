"""Reject unsafe MSI/CAB targets before the native decompressor is invoked."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'windows_msi_payload.py'
spec = importlib.util.spec_from_file_location('windows_msi_payload', SCRIPT)
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)


class PayloadTests(unittest.TestCase):
    def test_target_names(self):
        self.assertEqual(payload.leaf('SHORTN~1|long-name.dll:source'), 'long-name.dll')
        for name in ('..', '.', '../escape', 'C:\\escape', 'NUL', 'com1.txt',
                     'a:stream', 'trailing.', 'trailing ', 'tab\tfile'):
            # ':' separates the MSI target/source pair, so a:stream is a
            # legitimate target a. An ADS cannot survive target reconstruction.
            if name == 'a:stream':
                self.assertEqual(payload.leaf(name), 'a')
            else:
                with self.assertRaises(ValueError, msg=name):
                    payload.leaf(name)

    def test_cabinet_identifiers_checked_before_expand(self):
        with tempfile.TemporaryDirectory() as temp:
            cab = Path(temp) / 'fixture.cab'
            def write(names):
                header = bytearray(36)
                header[:4] = b'MSCF'
                struct.pack_into('<I', header, 16, 36)
                struct.pack_into('<H', header, 28, len(names))
                cab.write_bytes(header + b''.join(bytes(16) + n + b'\0' for n in names))
            write([b'valid_File.1'])
            self.assertEqual(payload.cabinet_members(cab), ['valid_File.1'])
            for names in ([b'../outside'], [b'C:\\outside'], [b'a/b'],
                          [b'.'], [b'Case', b'case']):
                write(names)
                with self.assertRaises(ValueError):
                    payload.cabinet_members(cab)


if __name__ == '__main__':
    unittest.main()
