"""Validate complete Tachyon images without depending on the installed OS GPT."""
import re
import struct
import xml.etree.ElementTree as ET
import zlib

SECTOR = 4096
PROGRAM_XML = [f'rawprogram{i}.xml' for i in range(7)]
PATCH_XML = [f'patch{i}.xml' for i in range(7)]
# Fixed hardware provisioning extents shared by Ubuntu 20.04, 24.04 and QLI.
NV = {'fsc': (32, 32), 'fsg': (64, 1024), 'modemst1': (1088, 1024),
      'modemst2': (2112, 1024), 'nvdata1': (3136, 384), 'nvdata2': (3520, 384)}
PROTECTED = [(5, start, count) for start, count in NV.values()] + [
    (5, 3904, 8192),  # Ubuntu 20.04 persist; retain it for downgrades.
    (4, 518, 128),    # UEFI variables.
    (0, 131078, 7680),  # Ubuntu 24.04 / QLI persist.
]


def sector_number(value, disk_sectors=None):
    if re.fullmatch(r'\d+', value):
        return int(value)
    match = re.fullmatch(r'NUM_DISK_SECTORS-([1-5])\.?', value)
    if match and disk_sectors is not None:
        return disk_sectors - int(match[1])
    raise ValueError(f'Unsupported sector expression or missing disk capacity: {value}')


def check_protected(lun, start, count):
    for protected_lun, protected_start, protected_count in PROTECTED:
        if lun == protected_lun and start < protected_start + protected_count and start + count > protected_start:
            raise ValueError(f'Write overlaps protected data on LUN {lun}: {start}+{count}')


def gpt_entries(main, backup):
    if len(main) != 6 * SECTOR or len(backup) != 5 * SECTOR:
        raise ValueError('Unexpected GPT payload size')
    tables = []
    for data, header_offset, entries_offset in ((main, SECTOR, 2*SECTOR), (backup, 4*SECTOR, 0)):
        header = bytearray(data[header_offset:header_offset+92])
        if header[:8] != b'EFI PART' or struct.unpack_from('<I', header, 12)[0] != 92:
            raise ValueError('Invalid GPT header')
        crc = struct.unpack_from('<I', header, 16)[0]
        struct.pack_into('<I', header, 16, 0)
        if zlib.crc32(header) != crc:
            raise ValueError('Invalid GPT header CRC')
        count, size, crc = struct.unpack_from('<III', header, 80)
        if size != 128 or not 0 < count <= 128:
            raise ValueError('Unexpected GPT entry geometry')
        entries = data[entries_offset:entries_offset+count*size]
        if zlib.crc32(entries) != crc:
            raise ValueError('Invalid GPT partition CRC')
        tables.append(entries)
    if tables[0] != tables[1]:
        raise ValueError('Primary and backup GPT partition tables differ')
    result = []
    for offset in range(0, len(tables[0]), 128):
        entry = tables[0][offset:offset+128]
        # ptool includes a zero-type last_parti placeholder that its patches grow.
        label = entry[56:128].decode('utf-16-le').rstrip('\0')
        if not label:
            continue
        first, last = struct.unpack_from('<QQ', entry, 32)
        result.append({'label': label, 'first': first, 'last': last, 'offset': offset})
    if len({p['label'] for p in result}) != len(result):
        raise ValueError('Duplicate GPT labels')
    return result


def expected_patches(lun, entries):
    """The existing assembler's disk-sizing and CRC operations, in order."""
    last_sector, last_offset = divmod(entries[-1]['offset'] + 40, SECTOR)
    array_bytes = ((len(entries) * 128 + 4095) // 4096) * 4096
    rows = []
    def add(start, offset, size, value, filename):
        rows.append((str(start).rstrip('.'), offset, size, value, filename))
    main, backup = f'gpt_main{lun}.bin', f'gpt_backup{lun}.bin'
    for start, filename in ((2 + last_sector, main), (2 + last_sector, 'DISK'),
                            (last_sector, backup), (f'NUM_DISK_SECTORS-{5-last_sector}.', 'DISK')):
        add(start, last_offset, 8, 'NUM_DISK_SECTORS-6.', filename)
    for start, filename in ((1, main), (1, 'DISK'), (4, backup), ('NUM_DISK_SECTORS-1.', 'DISK')):
        add(start, 48, 8, 'NUM_DISK_SECTORS-6.', filename)
    for filename in (main, 'DISK'):
        add(1, 32, 8, 'NUM_DISK_SECTORS-1.', filename)
    for start, filename in ((4, backup), ('NUM_DISK_SECTORS-1.', 'DISK')):
        add(start, 24, 8, 'NUM_DISK_SECTORS-1.', filename)
    for start, filename in ((4, backup), ('NUM_DISK_SECTORS-1', 'DISK')):
        add(start, 72, 8, 'NUM_DISK_SECTORS-5.', filename)
    for start, source, filename in ((1, '2', main), (1, '2', 'DISK'), (4, '0', backup),
                                     ('NUM_DISK_SECTORS-1.', 'NUM_DISK_SECTORS-5.', 'DISK')):
        add(start, 88, 4, f'CRC32({source},{array_bytes})', filename)
    for start, filename in ((1, main), (1, 'DISK'), (4, backup), ('NUM_DISK_SECTORS-1.', 'DISK')):
        add(start, 16, 4, '0', filename)
        add(start, 16, 4, f'CRC32({start},92)', filename)
    return rows


def validate_layout(read_bytes):
    """Read small metadata only; usable for a directory or a ZIP archive."""
    declarations = {}
    for lun in range(7):
        entries = gpt_entries(read_bytes(f'gpt_main{lun}.bin'), read_bytes(f'gpt_backup{lun}.bin'))
        by_label = {p['label']: p for p in entries}
        root = ET.fromstring(read_bytes(PROGRAM_XML[lun]))
        if root.tag != 'data':
            raise ValueError('Unexpected rawprogram root')
        seen = set()
        for p in root:
            a = p.attrib
            label = a.get('label')
            if p.tag != 'program' or int(a['physical_partition_number']) != lun or label in seen:
                raise ValueError('Unexpected or duplicate program operation')
            seen.add(label)
            if int(a['SECTOR_SIZE_IN_BYTES']) != SECTOR or int(a.get('file_sector_offset', '0')) != 0:
                raise ValueError('Unsupported program geometry')
            if a.get('sparse', 'false') != 'false':
                raise ValueError('Sparse payloads are not supported')
            if label in {'PrimaryGPT', 'BackupGPT'}:
                primary = label == 'PrimaryGPT'
                expected = (f'gpt_main{lun}.bin', '0', '6') if primary else (f'gpt_backup{lun}.bin', 'NUM_DISK_SECTORS-5.', '5')
                if (a['filename'], a['start_sector'], a['num_partition_sectors']) != expected:
                    raise ValueError('Unexpected GPT write')
            else:
                entry = by_label.get(label)
                start, count = int(a['start_sector']), int(a['num_partition_sectors'])
                if entry is None or start != entry['first']:
                    raise ValueError('Program and target GPT disagree')
                # The assembler uses zero for the final partition that grows.
                if count and start + count - 1 != entry['last']:
                    raise ValueError('Program capacity and target GPT disagree')
                if not count and entry != entries[-1]:
                    raise ValueError('Only the final partition may grow')
                declarations[(lun, label)] = a
        if seen != set(by_label) | {'PrimaryGPT', 'BackupGPT'}:
            raise ValueError('Incomplete GPT/program declarations')
        if lun == 5:
            for label, (start, count) in NV.items():
                entry = by_label.get(label, {})
                if (entry.get('first'), entry.get('last')) != (start, start + count - 1):
                    raise ValueError(f'Fixed provisioning geometry changed: {label}')
        patches = ET.fromstring(read_bytes(PATCH_XML[lun]))
        rows = []
        if patches.tag != 'patches':
            raise ValueError('Unexpected patch root')
        for p in patches:
            if p.tag != 'patch' or int(p.get('physical_partition_number')) != lun or int(p.get('SECTOR_SIZE_IN_BYTES')) != SECTOR:
                raise ValueError('Unexpected patch operation')
            rows.append((p.get('start_sector').rstrip('.'), int(p.get('byte_offset')),
                         int(p.get('size_in_bytes')), p.get('value'), p.get('filename')))
        if rows != expected_patches(lun, entries):
            raise ValueError(f'Unexpected GPT sizing/CRC patches on LUN {lun}')
    for key, extent in { (0, 'misc'): (138758, 256), (0, 'persist'): (131078, 7680),
                         (4, 'uefivarstore'): (518, 128)}.items():
        a = declarations.get(key, {})
        if (a.get('start_sector'), a.get('num_partition_sectors')) != tuple(map(str, extent)):
            raise ValueError(f'Required setup/persistent partition changed: {key}')
    return declarations
