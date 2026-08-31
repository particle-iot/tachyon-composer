# Flashing a Tachyon 24.04 image

## The short version

From inside the unzipped image directory:

```bash
particle flash --tachyon
particle tachyon restore
```

Or without unzipping:

```bash
particle flash --tachyon tachyon-ubuntu-24.04-<REGION>-<VARIANT>-<VERSION>.zip
particle tachyon restore
```

**There is no provisioning step.** If you have been told to run one, see
[Do not re-provision](#do-not-re-provision).

`particle tachyon setup` is equally safe — it calls the same code with the same image.

## Why the short version is the safe one

The image carries a `manifest.json` that lists exactly what to program:

```json
"program_xml": ["rawprogram0.xml", …, "rawprogram5.xml", "rawprogram6.xml"],
"patch_xml":   ["patch0.xml",      …, "patch5.xml",      "patch6.xml"]
```

`particle flash --tachyon` reads that list when you give it a **zip or a directory**, so it
programs every LUN the image needs and nothing it doesn't. When the layout changes, the
manifest changes with it and the command keeps working.

Given a **list of filenames** instead, the CLI passes them to qdl verbatim — no manifest, no
checks. That mode is why the two failures below exist.

## Driving qdl by hand

Sometimes you need to, and it is a reasonable thing to want. Two rules:

1. **Program all seven rawprograms.** There were six until 1.2.6, when #68 moved the firmware
   set — `uefi`, `tz`, `hyp`, `aop`, `devcfg`, `dtb`, `core_nhlos`, everything in the boot
   chain after XBL — from LUN 4 to LUN 6. A list that stops at `rawprogram5` leaves LUN 6
   unwritten, and the board hangs in XBL:

   ```
   B -   1054995 - sbl1_ddr_init, Start
   B -   1058380 - LP4 DDR detected
   ```

   That is XBL running off LUN 1, finishing DDR init, and finding nothing to hand off to. It
   is not a DDR fault.

2. **Never pass `provision_ufs22.xml`.** It is not a flashing step and your board does not
   need it. See below.

```bash
particle flash --tachyon prog_firehose_ddr.elf \
  rawprogram0.xml patch0.xml \
  rawprogram1.xml patch1.xml \
  rawprogram2.xml patch2.xml \
  rawprogram3.xml patch3.xml \
  rawprogram4.xml patch4.xml \
  rawprogram5.xml patch5.xml \
  rawprogram6.xml patch6.xml
particle tachyon restore
```

Prefer `particle flash --tachyon` with no arguments from that same directory. It does the
above from the manifest and cannot fall behind a layout change.

## Do not re-provision

`provision_ufs22.xml` re-carves the UFS chip into LUNs. It ships in the archive because the
factory bring-up path for a **blank** chip needs it. It is not a flashing step, and the CLI
never applies it on its own — only a hand-written command naming the file will.

**A Tachyon that boots is already provisioned correctly, so there is nothing to do.** The LUN
geometry is the same for 20.04 and 24.04 and always has been; both lines put the firmware set
on LUN 6 and the modem's NV on LUN 5 at the same offsets. That is the premise the current
24.04 layout is built on — it was chosen to fit the geometry boards already have, so that
flashing never has to touch LUN 5.

Measured on a factory board (`/sys/block/sd*/size`), which the descriptor in this repo now
matches exactly on every LUN:

| LUN | 1 | 2 | 3 | 4 | 5 | 6 |
| --- | --- | --- | --- | --- | --- | --- |
| KiB | 8192 | 8192 | 131072 | 131072 | 147456 | 1835008 |

### The copy shipped in 1.2.0 through 1.2.19 describes a different device

It was wrong on **all six** of those LUNs, not just the disabled LUN 6:

| LUN | 1 | 2 | 3 | 4 | 5 | 6 |
| --- | --- | --- | --- | --- | --- | --- |
| shipped | 16416 | 16416 | 32768 | 2621440 | 204800 | **0, disabled** |

It was self-consistent with the composer's *own* early layout, which put the firmware set on
LUN 4 — so "provision, then flash" worked as a pair up to 1.2.5, because provisioning re-cut
the board into the shape that image expected. It stopped working at 1.2.6, when the firmware
set moved to LUN 6 to match 20.04 and real hardware, and the descriptor did not follow.

**Applying that copy moves every LUN boundary from LUN 1 upward, so LUN 5 does not survive
it.** LUN 5 holds `fsg`, `fsc`, `modemst1/2` and `nvdata1/2` — the IMEI, both IMEIs on a
dual-SIM part, and the radio calibration written at manufacture. Those values are per-device.
They cannot be regenerated, and the cloud does not hold a copy for every device.

It is worse than a visible failure, because **the board boots and works perfectly without any
of it.** Nothing in normal operation reads LUN 5, so there is no symptom. Check with:

```bash
particle-tachyon-ril-ctl info
```

A genuine Tachyon reports `imei-1` beginning `86513606`. Firmware defaults look like a
Luhn-invalid IMEI, a `modem-serial-number` of `11111`, or a TAC of `86443001`.

Note this means a device flashed the manual way against **any** 1.2.x release before 1.2.20
may have lost its identity, including releases where the flash itself succeeded and the board
booted normally.

### Is re-provisioning with the corrected descriptor safe?

Unknown, and not worth finding out on a device you care about. The corrected descriptor
declares exactly the geometry the board already has, so there is no boundary for it to move —
but whether committing an identical UFS configuration descriptor leaves the logical units
untouched or re-formats them anyway has **not been tested here**, and the cost of being wrong
is an unrecoverable device. There is also no reason to run it: a factory board is already
correct.

## If a board is already in this state

1. `particle flash --tachyon <zip>` — the manifest-driven form repairs the partition layout
   and writes every LUN, including LUN 6.
2. `particle tachyon restore` — restores NV **if a backup exists**. `particle tachyon backup`
   must have been run before the damage, or a factory backup must exist in the cloud for that
   device.
3. Check `particle-tachyon-ril-ctl info`. If the IMEI is outside the `86513606` range and
   there is no backup, the modem's identity is not recoverable by any flashing procedure.

## Rolling back to 20.04

24.04 and 20.04 need different CDT platform ids (32 and 34), and 24.04 writes the CDT on
every flash. Rolling back needs a 20.04 image built from `tachyon-unpacking-tool` `a212b9e`
(PR #8) or later, which ships and writes its own CDT. Older 20.04 images do not, and will not
boot after a 24.04 flash — including after a *failed* one, since `cdt` on LUN 3 is written
before the large payloads. `particle tachyon backup` does not cover the CDT.
