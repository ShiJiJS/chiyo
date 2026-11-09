"""Read an MSI's embedded cabinets without running installer actions.

Uses read-only Windows Installer database APIs and expand.exe. Only regular,
bounded File-table identifiers are passed to expand; MSI destination directories
are rebuilt underneath a fresh caller-owned directory. No registry is written.
See https://learn.microsoft.com/en-us/windows/win32/msi/cabinet-files
and https://learn.microsoft.com/en-us/windows/win32/msi/-streams-table
"""
import ctypes
from ctypes import wintypes as w
from contextlib import contextmanager
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import os


class Database:
    def __init__(self, path):
        self.api = ctypes.WinDLL('msi')
        for name, args in {
            'MsiOpenDatabaseW': [w.LPCWSTR, w.LPCWSTR, ctypes.POINTER(w.UINT)],
            'MsiDatabaseOpenViewW': [w.UINT, w.LPCWSTR, ctypes.POINTER(w.UINT)],
            'MsiViewExecute': [w.UINT, w.UINT],
            'MsiViewFetch': [w.UINT, ctypes.POINTER(w.UINT)],
            'MsiRecordGetStringW': [w.UINT, w.UINT, w.LPWSTR, ctypes.POINTER(w.DWORD)],
            'MsiRecordReadStream': [w.UINT, w.UINT, ctypes.c_void_p, ctypes.POINTER(w.DWORD)],
            'MsiCloseHandle': [w.UINT],
        }.items():
            func = getattr(self.api, name)
            func.argtypes = args
            func.restype = w.UINT
        self.handle = w.UINT()
        self.check(self.api.MsiOpenDatabaseW(str(path), None, ctypes.byref(self.handle)))

    @staticmethod
    def check(result):
        if result:
            raise OSError('Read-only MSI operation failed: ' + str(result))

    def close(self):
        self.api.MsiCloseHandle(self.handle)

    @contextmanager
    def records(self, sql):
        view = w.UINT()
        self.check(self.api.MsiDatabaseOpenViewW(self.handle, sql, ctypes.byref(view)))
        try:
            self.check(self.api.MsiViewExecute(view, 0))

            def rows():
                while True:
                    record = w.UINT()
                    result = self.api.MsiViewFetch(view, ctypes.byref(record))
                    if result == 259:
                        return
                    self.check(result)
                    try:
                        yield record
                    finally:
                        self.api.MsiCloseHandle(record)
            yield rows()
        finally:
            self.api.MsiCloseHandle(view)

    def string(self, record, column):
        size = w.DWORD(0)
        result = self.api.MsiRecordGetStringW(record, column, None, ctypes.byref(size))
        if result not in (0, 234) or size.value > 32768:
            raise ValueError('MSI string size')
        size.value += 1
        buffer = ctypes.create_unicode_buffer(size.value)
        self.check(self.api.MsiRecordGetStringW(record, column, buffer, ctypes.byref(size)))
        return buffer.value

    def table(self, table, columns):
        with self.records('SELECT ' + ','.join('`' + c + '`' for c in columns)
                          + ' FROM `' + table + '`') as records:
            return [tuple(self.string(r, i + 1) for i in range(len(columns))) for r in records]

    def cabinet(self, name, destination):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', name):
            raise ValueError('Unexpected embedded cabinet name')
        with self.records("SELECT `Data` FROM `_Streams` WHERE `Name`='" + name + "'") as records:
            found = False
            for record in records:
                if found:
                    raise ValueError('Duplicate cabinet')
                found = True
                buffer = ctypes.create_string_buffer(1024 * 1024)
                total = 0
                with destination.open('xb') as output:
                    while True:
                        count = w.DWORD(len(buffer))
                        self.check(self.api.MsiRecordReadStream(record, 1, buffer, ctypes.byref(count)))
                        if not count.value:
                            break
                        total += count.value
                        if total > 512 * 1024 * 1024:
                            raise ValueError('Oversized cabinet')
                        output.write(buffer.raw[:count.value])
            if not found:
                raise ValueError('Missing embedded cabinet')


def leaf(value):
    if re.match(r'^[A-Za-z]:[\\/]', value):
        raise ValueError('Absolute MSI name')
    value = value.split(':', 1)[0].split('|')[-1]
    if (not value or value in ('.', '..') or value.endswith((' ', '.'))
            or re.search(r'[\\/:<>"|?*\x00-\x1f]', value)
            or re.fullmatch(r'(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?', value)):
        raise ValueError('Unsafe MSI target name')
    return value


def cabinet_members(path):
    data = path.read_bytes()
    if len(data) < 36 or data[:4] != b'MSCF':
        raise ValueError('Invalid cabinet header')
    offset, = struct.unpack_from('<I', data, 16)
    count, = struct.unpack_from('<H', data, 28)
    names = []
    for _ in range(count):
        offset += 16
        end = data.index(b'\0', offset, offset + 513)
        name = data[offset:end].decode('ascii')
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', name) or name in ('.', '..'):
            raise ValueError('Unsafe cabinet member')
        names.append(name)
        offset = end + 1
    if len(set(n.casefold() for n in names)) != len(names):
        raise ValueError('Duplicate cabinet member')
    return names


def extract(msi, destination, scratch):
    """Extract all declared files to a fresh directory; never execute the MSI."""
    destination = Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError('MSI destination must be new')
    database = Database(Path(msi).resolve(strict=True))
    try:
        directories = {key: (parent, default) for key, parent, default in database.table(
            'Directory', ['Directory', 'Directory_Parent', 'DefaultDir'])}
        components = dict(database.table('Component', ['Component', 'Directory_']))
        files = database.table('File', ['File', 'Component_', 'FileName', 'FileSize'])
        cabinets = database.table('Media', ['Cabinet'])
        paths = {}

        def directory(key, seen=()):
            if key in seen or len(seen) > 64:
                raise ValueError('Cyclic MSI directory')
            parent, default = directories[key]
            if not parent:
                return Path()
            root = directory(parent, (*seen, key))
            target = default.split(':', 1)[0].split('|')[-1]
            return root if target == '.' else root / leaf(default)

        for key, component, name, size in files:
            if not re.fullmatch(r'[A-Za-z0-9_.-]+', key) or key in paths:
                raise ValueError('Invalid File key')
            paths[key] = (directory(components[component]) / leaf(name), int(size))
        targets = [str(row[0]).casefold() for row in paths.values()]
        if len(set(targets)) != len(targets) or len(paths) > 20000:
            raise ValueError('Duplicate/oversized MSI payload')
        destination.mkdir(parents=True)
        with tempfile.TemporaryDirectory(prefix='msi-payload-', dir=scratch) as temp:
            temporary = Path(temp)
            copied = set()
            for i, (name,) in enumerate(cabinets):
                if not name.startswith('#'):
                    raise ValueError('Only embedded cabinets supported')
                cabinet = temporary / f'{i}.cab'
                database.cabinet(name[1:], cabinet)
                members = cabinet_members(cabinet)
                if any(n not in paths or n in copied for n in members):
                    raise ValueError('Undeclared/repeated cabinet member')
                flat = temporary / f'{i}-files'
                flat.mkdir()
                subprocess.run([str(Path(os.environ['SystemRoot']) / 'System32/expand.exe'),
                                '-F:*', str(cabinet), str(flat)], check=True,
                               stdout=subprocess.DEVNULL)
                if {p.name for p in flat.iterdir()} != set(members):
                    raise ValueError('Unexpected expanded files')
                for member in members:
                    source = flat / member
                    relative, size = paths[member]
                    if source.is_symlink() or not source.is_file() or source.stat().st_size != size:
                        raise ValueError('Expanded file identity/size')
                    target = destination / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
                    copied.add(member)
            if copied != set(paths):
                raise ValueError('Incomplete MSI payload')
    finally:
        database.close()


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('msi', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--scratch', type=Path, required=True)
    args = parser.parse_args()
    extract(args.msi, args.destination, args.scratch)
