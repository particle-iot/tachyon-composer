#!/usr/bin/env python3
"""Check the UFS provisioning descriptor against the partition layout ptool generated.

Why this exists
---------------
`provision_ufs22.xml` declares how the UFS chip is carved into LUNs. `partition_ext.xml`
declares which partitions live on which LUN. Nothing connected the two, so they drifted --
twice, both times shipping:

  * The original LUN 4 overrun. The 24.04 layout started writing `core_nhlos_a` at sector
    31770 of a LUN that 20.04 provisions with 32768 sectors, and needed 43520 of them. Every
    flash onto a 20.04-geometry board died with a USB bulk-write timeout, because firehose
    surfaces a write past the end of a LUN as a transport error rather than a size error.

  * `bLUEnable="0"` on LUN 6. The shipped descriptor described a device nobody has: it was
    wrong on all six of LUNs 1-6 against a measured factory board, but self-consistent with
    the composer's own early layout, which put the firmware set on LUN 4. #68 then moved that
    set -- `uefi`, `tz`, `hyp`, `aop`, `devcfg`, `dtb`, `core_nhlos`, the entire boot chain
    after XBL -- onto LUN 6, matching 20.04 and real hardware. The descriptor did not follow,
    so applying it deleted the LUN the image needs: the next flash failed at "failed to setup
    programming", and a board flashed the manual way hung in XBL at `LP4 DDR detected` with
    nothing to hand off to.

Both are the same class of defect: the descriptor and the layout disagreeing, with the
symptom appearing far from the cause. This runs against the *generated* rawprograms rather
than the source XML, so it catches the disagreement however it arose.

Severities
----------
FATAL   a LUN the layout uses is disabled in the descriptor
FATAL   a partition WITH A PAYLOAD whose extent exceeds its provisioned LUN
FATAL   bConfigDescrLock is not 0, or the commit epilogue is missing
WARN    a payload-less partition declared past the end of its LUN -- latent, because nothing
        writes those sectors today, but it will fail the moment something does

Notes
-----
* The grow LUN (`LUNtoGrow`) is exempt from the extent check: its declared size is a floor,
  and GROW_LAST_PARTITION_TO_FILL_DISK expands it to whatever the SKU provides.
* `start_sector="NUM_DISK_SECTORS-N."` is end-relative by definition (the backup GPT lives
  at the end of the LUN), so those entries are skipped rather than treated as an overrun.
* Sector size is derived per LUN from `size_in_KB` / `num_partition_sectors` rather than
  assumed, and disagreement inside one LUN is itself an error.
"""

import argparse
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

SYMBOLIC_START = re.compile(r'^\s*NUM_DISK_SECTORS')


def parse_provisioning(path):
    """-> (luns{num: {enabled, size_kb}}, grow_lun, config_descr_lock, has_commit)"""
    root = ET.parse(path).getroot()
    luns, grow, lock, commit = {}, None, None, False
    for el in root.iter('ufs'):
        a = el.attrib
        if 'LUNum' in a:
            luns[int(a['LUNum'])] = {
                'enabled': a.get('bLUEnable') == '1',
                'size_kb': int(a.get('size_in_kb', '0')),
            }
        if 'bConfigDescrLock' in a:
            lock = int(a['bConfigDescrLock'], 0)
        if 'LUNtoGrow' in a:
            grow = int(a['LUNtoGrow'])
        if a.get('commit') == '1':
            commit = True
    return luns, grow, lock, commit


def parse_rawprograms(paths):
    """-> {lun: [ {label, start, sectors, has_payload, symbolic, sector_bytes} ]}"""
    by_lun = {}
    for p in paths:
        for el in ET.parse(p).getroot().iter('program'):
            a = el.attrib
            lun = int(a['physical_partition_number'])
            start_raw = a.get('start_sector', '0')
            sectors = int(a.get('num_partition_sectors', '0'))
            size_kb = float(a.get('size_in_KB', '0') or 0)
            sector_bytes = None
            if sectors > 0 and size_kb > 0:
                sector_bytes = int(round(size_kb * 1024 / sectors))
            by_lun.setdefault(lun, []).append({
                'label': a.get('label', '?'),
                'file': os.path.basename(p),
                'start': None if SYMBOLIC_START.match(start_raw) else int(start_raw),
                'sectors': sectors,
                'has_payload': bool(a.get('filename', '').strip()),
                'symbolic': bool(SYMBOLIC_START.match(start_raw)),
                'sector_bytes': sector_bytes,
            })
    return by_lun


# --------------------------------------------------------------------------------------
# Regression cases. Both of these shipped; each must stay caught.
# --------------------------------------------------------------------------------------

_PROV_TMPL = """<?xml version="1.0" ?>
<data>
  <ufs bNumberLU="0" bConfigDescrLock="{lock}" />
{luns}
  <ufs LUNtoGrow="0" {commit}/>
</data>
"""
_LUN_TMPL = '  <ufs LUNum="{n}" bLUEnable="{en}" size_in_kb="{kb}" />'

_RAW_TMPL = """<?xml version="1.0" ?>
<data>
{progs}
</data>
"""
_PROG_TMPL = ('  <program start_sector="{start}" size_in_KB="{kb}" '
              'physical_partition_number="{lun}" num_partition_sectors="{n}" '
              'label="{label}" filename="{file}" />')


def _write_case(tmp, luns, progs, lock=0, commit=True):
    lun_xml = "\n".join(_LUN_TMPL.format(n=n, en=1 if en else 0, kb=kb)
                        for n, en, kb in luns)
    prov = os.path.join(tmp, 'provision.xml')
    with open(prov, 'w') as fh:
        fh.write(_PROV_TMPL.format(lock=lock, luns=lun_xml,
                                   commit='commit="1"' if commit else ''))
    by_lun = {}
    for lun, label, start, n, has_file in progs:
        by_lun.setdefault(lun, []).append(
            _PROG_TMPL.format(start=start, kb=n * 4096 / 1024, lun=lun, n=n,
                              label=label, file=(label + '.img') if has_file else ''))
    for lun, entries in by_lun.items():
        with open(os.path.join(tmp, f'rawprogram{lun}.xml'), 'w') as fh:
            fh.write(_RAW_TMPL.format(progs="\n".join(entries)))
    return prov


def _run(prov, tmp):
    import subprocess
    r = subprocess.run([sys.executable, os.path.abspath(__file__),
                        '--provision', prov, '--dir', tmp],
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def self_test():
    import shutil
    import tempfile
    cases = []

    # 1) The original LUN 4 overrun: core_nhlos_a starts at 31770 and needs 43520 sectors
    #    on a LUN provisioned with 32768. It HAS a payload, so this must be fatal.
    cases.append(('LUN 4 overrun (the USB bulk-write timeout)', 1, 'will fail',
                  [(0, True, 4096), (4, True, 32768 * 4)],
                  [(0, 'system', 6, 100, True),
                   (4, 'core_nhlos_a', 31770, 43520, True)]))

    # 2) LUN 6 disabled while the firmware set lives there (#68 vs the stale descriptor).
    cases.append(('LUN 6 used but disabled', 1, 'DISABLED in the descriptor',
                  [(0, True, 4096), (6, False, 0)],
                  [(0, 'system', 6, 100, True),
                   (6, 'uefi_a', 6, 128, True)]))

    # 3) A payload-less partition past the end is latent, not fatal.
    cases.append(('payload-less overrun is a warning', 0, 'as soon as something does',
                  [(0, True, 4096), (1, True, 8192)],
                  [(0, 'system', 6, 100, True),
                   (1, 'xbl_a', 6, 901, True),
                   (1, 'xbl_b', 1035, 1029, False)]))

    # 4) A clean layout passes.
    cases.append(('clean layout passes', 0, 'validation passed',
                  [(0, True, 4096), (6, True, 1835008)],
                  [(0, 'system', 6, 100, True),
                   (6, 'uefi_a', 6, 128, True)]))

    # 5) A locked descriptor is fatal -- it cannot be re-provisioned afterwards.
    cases.append(('bConfigDescrLock must be 0', 1, 'bConfigDescrLock',
                  [(0, True, 4096)], [(0, 'system', 6, 100, True)]))

    # 6) A missing commit epilogue is fatal -- computed and never written.
    cases.append(('commit epilogue required', 1, 'epilogue',
                  [(0, True, 4096)], [(0, 'system', 6, 100, True)]))

    failures = 0
    for i, (name, want_rc, want_text, luns, progs) in enumerate(cases):
        tmp = tempfile.mkdtemp()
        try:
            lock = 1 if 'bConfigDescrLock' in name else 0
            commit = 'commit epilogue' not in name
            prov = _write_case(tmp, luns, progs, lock=lock, commit=commit)
            rc, out = _run(prov, tmp)
            ok = (rc == want_rc) and (want_text in out)
            print(f'  [{"PASS" if ok else "FAIL"}] {name}')
            if not ok:
                failures += 1
                print(f'         wanted rc={want_rc} and {want_text!r}, got rc={rc}')
                print('         ' + out.replace(chr(10), chr(10) + '         '))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    print(f'\nself-test: {len(cases) - failures}/{len(cases)} passed')
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--provision', required=False)
    ap.add_argument('--dir', required=False,
                    help='directory holding the generated rawprogramN.xml files')
    ap.add_argument('--warnings-fatal', action='store_true',
                    help='treat latent overruns as errors too')
    ap.add_argument('--self-test', action='store_true',
                    help='run the built-in regression cases and exit')
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if not args.provision or not args.dir:
        ap.error('--provision and --dir are required unless --self-test is given')

    # Only the canonical set. The _BLANK_GPT and _WIPE_PARTITIONS variants describe
    # deliberately destructive operations and are not what a normal flash programs.
    raws = sorted(p for p in glob.glob(os.path.join(args.dir, 'rawprogram[0-9].xml')))
    if not raws:
        print(f'ERROR: no rawprogram[0-9].xml in {args.dir}', file=sys.stderr)
        return 1

    luns, grow, lock, commit = parse_provisioning(args.provision)
    layout = parse_rawprograms(raws)
    errors, warnings = [], []

    if lock != 0:
        errors.append(f'bConfigDescrLock is {lock}, must be 0 -- a locked descriptor cannot '
                      f'be re-provisioned, which would make the board unrecoverable')
    if not commit:
        errors.append('no <ufs ... commit="1"/> epilogue -- the descriptor would be computed '
                      'and never written')

    for lun in sorted(layout):
        parts = layout[lun]
        cfg = luns.get(lun)
        used_labels = ' '.join(p['label'] for p in parts if p['has_payload']) or '(no payloads)'

        if cfg is None:
            errors.append(f'LUN {lun} is used by the layout but absent from the descriptor '
                          f'(payloads: {used_labels})')
            continue
        if not cfg['enabled']:
            errors.append(f'LUN {lun} is used by the layout but DISABLED in the descriptor '
                          f'(bLUEnable="0", size_in_kb={cfg["size_kb"]}). '
                          f'Payloads that would be lost: {used_labels}')
            continue

        sizes = {p['sector_bytes'] for p in parts if p['sector_bytes']}
        if len(sizes) > 1:
            errors.append(f'LUN {lun} has inconsistent sector sizes {sorted(sizes)} across '
                          f'its entries')
            continue
        sector_bytes = sizes.pop() if sizes else 4096

        if lun == grow:
            print(f'  LUN {lun}: grow LUN (LUNtoGrow), extent check skipped; '
                  f'{len(parts)} entries')
            continue

        capacity_kb = cfg['size_kb']
        worst = None
        for p in parts:
            if p['symbolic'] or p['sectors'] == 0:
                continue
            end_kb = (p['start'] + p['sectors']) * sector_bytes // 1024
            if end_kb <= capacity_kb:
                continue
            over = end_kb - capacity_kb
            msg = (f'LUN {lun}: "{p["label"]}" ends at {end_kb} KiB but the LUN is '
                   f'{capacity_kb} KiB -- over by {over} KiB ({p["file"]})')
            if p['has_payload']:
                errors.append(msg + '. This partition HAS a payload, so the flash will fail.')
            else:
                warnings.append(msg + '. No payload today, so nothing writes those sectors; '
                                      'this fails as soon as something does (e.g. an A/B '
                                      'update writing the B slot).')
            if worst is None or over > worst:
                worst = over
        if worst is None:
            print(f'  LUN {lun}: OK, {len(parts)} entries fit in {capacity_kb} KiB')

    sys.stdout.flush()
    for w in warnings:
        print(f'WARN: {w}', file=sys.stderr)
    for e in errors:
        print(f'ERROR: {e}', file=sys.stderr)

    if errors or (warnings and args.warnings_fatal):
        print(f'\nprovisioning validation FAILED '
              f'({len(errors)} error(s), {len(warnings)} warning(s))', file=sys.stderr)
        return 1
    print(f'provisioning validation passed ({len(warnings)} warning(s))')
    return 0


if __name__ == '__main__':
    sys.exit(main())
