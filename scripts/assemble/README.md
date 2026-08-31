# make-factory-img

This directory contains a self-contained UFS packaging tool. It does not depend on any other directory in the repository.

## Inputs

- `QCM6490_bootbinaries.zip`
- partition images passed as `--<partition_name> /path/to/file`

## Usage

```bash
scripts/assemble/make_factory_img.sh \
  --bootbinaries /path/to/QCM6490_bootbinaries.zip \
  --efi /path/to/efi.img \
  --dtb_a /path/to/dtb.img \
  --core_nhlos_a /path/to/nonhlos.img \
  --system /path/to/system.img
```

The default output directory is `output/` under the current working directory.

To override the output path, pass:

```bash
--output /path/to/out
```

## Output

The output directory contains:

- extracted bootbinaries files
- copied partition files that were passed on the command line
- `cdt.bin`
- `partition_ext.xml`
- `rawprogram0.xml` through **`rawprogram6.xml`**
- `patch0.xml` through **`patch6.xml`**
- `gpt_main*`, `gpt_backup*`, `gpt_both*`, and `gpt_empty*`
- `provision_ufs22.xml` — **not part of flashing, see below**

### There are seven LUNs, not six

`rawprogram6.xml` carries the firmware set — `uefi`, `tz`, `hyp`, `aop`, `devcfg`, `dtb`,
`core_nhlos` and the rest of the boot chain after XBL. #68 moved it from LUN 4 to LUN 6,
first shipped in 1.2.6, which put 24.04 back in line with 20.04 and with the geometry real
boards have — both have always used LUN 6 for firmware. **Any hand-written list of rawprograms that stops at 5 will
produce a board that hangs in XBL at `LP4 DDR detected`**, because XBL comes up off LUN 1
and then has nothing to hand off to. This README said "through `rawprogram5.xml`" until
that was fixed, and that is where at least one such list came from.

If you are driving qdl by hand, don't enumerate the files. See
[`FLASHING.md`](../../FLASHING.md).

### `provision_ufs22.xml` is not a flashing step

It re-carves the UFS chip into LUNs. It is emitted here because the factory bring-up path for
a **blank** chip needs it, and for no other reason.

**Do not apply it to a Tachyon that already boots.** It re-creates LUN 5, which is where the
modem keeps `fsg`, `fsc`, `modemst1/2` and `nvdata1/2` — the IMEI and radio calibration
programmed at manufacture. Re-provisioning loses them, they cannot be regenerated, and
`particle tachyon backup` must have been taken beforehand to have any chance of recovery. The
damage is also silent: the board boots and runs perfectly without any of it, so the only way
to notice is `particle-tachyon-ril-ctl info` reporting an IMEI outside the `86513606` range.

A device that came from the factory is already provisioned correctly, which is the whole
premise of #68 — the layout was chosen to fit the geometry boards already have so that
flashing never has to touch LUN 5. The LUN geometry is the same for 20.04 and 24.04 and
always has been; there has never been a "24.04 provisioning".

The copy shipped in 1.2.0–1.2.19 was wrong on all six of LUNs 1–6, not just LUN 6. It was
self-consistent with the composer's own early LUN 4 layout, so "provision then flash" worked
as a pair up to 1.2.5 — which is exactly why the recipe circulated. Applying it moves every
boundary from LUN 1 upward, LUN 5 included.

## Notes

- The script copies `partition_ext.xml` into the output directory and updates `filename=` for every partition label passed on the command line.
- Partition names must match `label=` values in `partition_ext.xml` exactly.
- If a partition label appears multiple times in `partition_ext.xml`, every matching entry is updated.
