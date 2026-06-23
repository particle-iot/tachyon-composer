# scripts/signing

Self-contained signer for the Tachyon system image. The composer calls this tool to (re-)sign the
boot/firmware blobs of the EDL image with a **selectable key**. It is deliberately **separable**:
the whole `scripts/signing/` folder (plus the repo-root `keys/` folder) can be lifted into its own
repository unchanged.

## Model

The BP firmware artifact ships the boot blobs already **TEST-signed** (signed inside the Qualcomm
sub-builds). This tool **re-signs** them with the selected key — the same stock TEST key for now
(proving the selectable-key path), a real OEM/prod key later. Re-signing a signed image is supported
by sectoolsv2: it regenerates the hash table + certificate chain.

Signing is a whole-build concern owned here, not buried in the BP firmware repo. The BP repo is
referenced only as a published artifact, never as a build dependency.

## Contents

- `sign.sh` — the CLI entry point the composer calls. Re-signs every blob marked `sign=yes` in the
  map, regenerates `multi_image.mbn`, and passes everything else through.
- `image-map.tsv` — authoritative `filename → image-id` map (e.g. `xbl.elf → XBL`, `uefi.elf → UEFI`),
  derived by `sectools --validate` against the released signed bootbinaries.
- `sectools/` — the **committed** Qualcomm sectoolsv2 signer: just two files so CI signs without a
  BP-repo checkout —
  - `ext/Linux_aarch64/sectools` — the aarch64 sectoolsv2 binary (runs in the arm64 builder),
  - `kodiak_security_profile.xml` — the QCM6490 (KODIAK) security profile (defines chipset + image-ids).
- `vendor-sectools.sh` — dev/maintenance helper to refresh those two files from a local BP-fw
  checkout (`--from-bp`) or from URLs, when the BP toolchain bumps.

Key material lives in the repo-root `keys/` folder — **test keys only** (see `keys/README.md`).

## Usage

```bash
# (maintenance only) refresh the vendored signer from a BP-fw checkout:
./vendor-sectools.sh --from-bp /path/to/tachyon-quectel-bp-fw

# re-sign a dir of blobs into a dir of signed blobs (the composer calls this):
./sign.sh --in <bootbinaries> --out <signed> --profile test --fw-dir <QCM6490_fw>
# profile/key default from ../../versions.json "signing" block when omitted.
```

`--fw-dir` is the extracted `QCM6490_fw` tree: `multi_image.mbn` vouches for ADSP/CDSP/WPSS, which
live there (not in the bootbinaries). Without it, `multi_image` is carried over unchanged and flagged
as stale.

## Selectable key (`--profile`)

| Profile | Behaviour |
|---|---|
| `test` (default) | sectoolsv2 `--signing-mode TEST` — built-in Qualcomm test keys, no key material needed. **Not production-secure.** |
| `prod` | `--signing-mode LOCAL` with an OEM key supplied at build time via `SIGNING_KEY_PATH` (a mounted dir / CI secret), **never committed**. Wired; prod key flags populated at prod enablement. |
| `none` | Passthrough — copy every input unchanged, sign nothing (keep the BP test signing). |

To go to production: set `signing.profile = prod` in `versions.json`, mount the OEM key dir at
`SIGNING_KEY_PATH`, and populate the prod key flags in `sign.sh`.

## What gets signed

The boot/firmware ELF/MBN blobs listed `sign=yes` in `image-map.tsv` are re-signed per-blob via:

```
sectools secure-image <blob> --image-id <ID> --security-profile kodiak_security_profile.xml \
  --outfile <out> --sign --signing-mode <TEST|LOCAL>
```

Re-signing changes their hashes, so `multi_image.mbn` is then **regenerated** (not re-signed) to
vouch for the re-signed set — 10 boot blobs + ADSP/CDSP/WPSS from `--fw-dir`:

```
sectools secure-image --vouch-for <13 files> --image-id QUPV3 AOP SHRM XBL-CONFIG UEFI \
  XBL-RAM-DUMP CPUCP TZ QHEE TZ-DEVCFG ADSP CDSP WPSS --security-profile kodiak ... \
  --outfile multi_image.mbn
```

Not signed here (`sign=no` in the map): partition tables, `logfs`, `cdt.bin`, the Qualcomm
proprietary marker, `uefi_sec.mbn`/`imagefv.elf` (FV components folded into `uefi.elf`), and the
filesystem/data images (`efi`, `system/rootfs`, `dtb`, `nonhlos`) — their integrity comes from the
boot chain / GRUB, and `nonhlos` is a plain FAT filesystem.

## Runtime note

sectoolsv2 is a PyInstaller bundle that `dlopen()`s `libcrypt.so.2`; Ubuntu 24.04 ships only
`libcrypt.so.1`. The composer Dockerfile symlinks it, and `sign.sh` also installs a root-free
`LD_LIBRARY_PATH` shim, so it runs either way.
