# Particle A/B OTA system — shared image library, custom format, CLI, CI validators, on-device service

## Context

Tachyon is moving to a symmetric A/B partition layout (new-BP 24.04: `efi_a/b`, `system_a/b`,
shared `persist`/`userdata`, modem NV on LUN5). Today the composer emits a Qualcomm-style factory
image and `particle-cli` flashes it wholesale over EDL/`qdl`; there is **no** selective-slot flash,
**no** slot toggle, and **no** on-device update path.

We want **one CICD build image** that can be emitted in **three formats** — (a) **factory** (all
partitions, including the erase/zero ops that blow the device away), (b) **OTA-image** (just
`efi`+`system` for one slot A *or* B), (c) **OTA+boot** (all boot/firmware partitions + an OTA-image;
userdata optional) — driven by a **Particle-owned intermediate format** (NOT a Qualcomm manifest)
that a tool can manipulate and expand into any of the three.

**The core of this design is a single shared JS library** that holds *all* the image logic —
parsing, building, signing, verifying, validating, format-expansion, sparse/chunk handling, and the
partition **operation model** — with its own unit tests. Every other component is a thin consumer of
that library so the logic is written once:

- **tachyon-composer** — generate the `particle-image` + validate it.
- **particle-tachyon-ota** — the on-device service that applies it.
- **cloud server** — parse/validate uploaded images.
- **particle-cli** — flash/slot/delta using the same parsing + verification.

**Decisions locked with the user:** all deliverables planned together; on-device service in
**Node.js** (matches particle-service/`dbus-native`/PolicyKit); container is a **ZIP, manifest-first**;
trust model is a **signed manifest carrying per-partition hashes**, verified against a baked-in
Particle public key before any write; **common logic lives in shared library files that are
themselves unit-tested**, not re-implemented per consumer.

## Workflow constraints & branch setup

- **Never push.** All work stays local — feature branches and local commits only; no `git push`, no
  PRs, until the user explicitly asks.
- **Branch per repo (off the latest default branch):**
  - `tachyon-composer`: discard the uncommitted `partition_ext.xml` experiment
    (`git checkout -- scripts/assemble/config/partition_ext.xml`), then branch
    **`feature/ota-image-format`** off `main` (carry `OTA.md` over).
  - `particle-cli` (`../../cli/particle-cli`): default branch is **`master`** — pull latest, then
    branch **`feature/tachyon-ota-ab`**. Leave the existing untracked backup artifacts alone.
  - `particle-tachyon-image`, `particle-tachyon-ota`: new repos (`git init`, initial local commit).
- **Everything must run.** Build + unit-test the shared lib and CLI as they're written; the CLI gains
  a **`--dry-run`** mode (below) so the full flash/slot/update path is exercisable with no hardware.

## Evidence from the real published factory image (verified)

Range-fetched the central directory + XML entries of the live RoW factory zip
`https://linux-dist.particle.io/release/Tachyon_EMPAR03A06_BP10.001V02_Ubuntu20.04.003.51.004V02_factory.zip`
(~2.7 GB, server supports byte ranges — no full download needed). Findings that shape the format:

- **Root `manifest.json` is `image_manifest_v1`** — identical schema to what the composer emits and
  what `particle flash --tachyon` already parses: `targets[].qcm6490.edl.{base, firehose,
  program_xml[], patch_xml[]}`. The new format must round-trip *to/from* this.
- **The factory really does blow partitions away** — `rawprogram_unsparse0.xml` begins with explicit
  `<erase>` ops on `frp`, `art`, `keystore`, `ssd`, `misc`, and a full
  `<erase label="system_a" num_partition_sectors="2097152" filename="">` before any data is written.
- **Two distinct zeroing mechanisms exist:** UFS `<erase>` (unmap, used by the 20.04 factory) and
  writing a zeros file (`zero.bin` / the new-BP composer's `zeros_1sector.bin` in
  `rawprogram*_WIPE_PARTITIONS.xml`). The op model must represent both.
- **The OS is written as ~61 sequential `<program>` chunks** (`sysfs_1.ext4 … sysfs_61.ext4`), each
  at an increasing `start_sector` with its own `num_partition_sectors`. The device already streams
  the system in decodable, offset-ordered chunks — directly aligned with our streaming requirement.
- **GPT grow math lives in `patch*.xml`** — `NUM_DISK_SECTORS-N` arithmetic + `CRC32(...)` recompute
  of primary/backup headers (confirmed against the composer's own `patch0.xml`). This is a first-class
  operation, not a file.
- LUN0 uses `rawprogram_unsparse0.xml` (not `rawprogram0.xml`); there are also `*_BLANK_GPT.xml`
  variants. The library's importer must tolerate all of these names.

Net: the format and library model a **partition operation graph** — `program` (chunked/sparse) ·
`erase` · `zero` · `patch` (GPT arithmetic + CRC) · `gpt` — not merely "a list of images."

## Deliverable 0 (centerpiece) — shared library `particle-tachyon-image`

New repo at **`../particle-tachyon-image`** (i.e. `/Users/nicklambourne/Documents/particle/tachyon/particle-tachyon-image`,
sibling of tachyon-composer; to be created) — npm package, recommend **TypeScript**, emit CommonJS+ESM
(it is a contract shared by four consumers; types prevent drift). Every module is independently unit-tested (the user's explicit
requirement: *the common files themselves need tests*). Modules:

- **`model/`** — the in-memory **operation graph**: `Device → LUN[] → Partition{label, lun, slot,
  role, group, size, start_sector, num_sectors, type_guid}` with an ordered op list per partition
  (`{op: 'program'|'erase'|'zero'|'patch'|'gpt', source?, chunks?[], sparse?, gptArith?}`). This is
  the single representation everything imports to / exports from.
- **`manifest/`** — the **`particle_image_v1`** schema (parse/build/validate) AND an importer/exporter
  for the legacy **`image_manifest_v1`** QCOM manifest + `rawprogram*/rawprogram_unsparse*/patch*/
  *_WIPE_PARTITIONS*/*_BLANK_GPT*` XML (so we can ingest the real factory image and re-emit qdl XML).
- **`xml/`** — rawprogram/patch/erase XML reader+writer (the `<program>/<erase>/<patch>` grammar,
  `NUM_DISK_SECTORS` arithmetic, `start_byte_hex`, `partofsingleimage`). Reused to *emit qdl-ready
  XML* for the CLI and to *parse* device/real-factory XML.
  **Prior art — learn from, do not depend on:** the QCOM XML grammar is already implemented in
  existing open-source flashers, so we read their parsers for the edge cases (patch CRC ops,
  `partofsingleimage`, sparse/erase handling) rather than guessing from samples. Best references:
  **linux-msm/qdl** (C, BSD-3 — authoritative upstream) and **bkerler/edl** (Python, GPL-3 — most
  complete `xmlparser`/`gpt`). We implement our own in TS (no JS/TS lib exists; avoids the GPL/Python
  coupling) but crib the grammar from these. We also need a superset anyway (op-graph +
  `particle_image_v1` + signing), which no existing library provides.
- **`signing/`** — ed25519 sign + verify over **JCS-canonicalised** manifest (blank-signature-then-
  sign); profile/key resolution mirroring `versions.json.signing` and the `keys/` convention.
- **`hash/`** — sha256 of compressed entry + `payload_sha256` of the fully-expanded raw image (holes
  as zeros), shared by emitter, validator, device writer, and delta compare.
- **`sparse/`** — Android sparse encode/decode (RAW/FILL/DONT_CARE/CRC32) as streams; plus the
  multi-chunk reader/writer (the `sysfs_N` pattern) so chunked images decode straight to offsets.
- **`format/`** — **expansion**: given the operation graph, select the op/partition subset for
  `factory` | `ota-image(slot)` | `ota-boot(slot, includeUserdata?)`, including which `erase`/`zero`
  ops belong to each (factory wipes everything; ota-image erases+writes one slot's system/efi).
- **`zip/`** — manifest-first ZIP read/write with **streaming** (sequential, partition-decodable
  order) and random-access single-entry extraction (central directory).
- **`validate/`** — all checks (see Deliverable 2) expressed against the model so composer CI, the
  cloud server, and the CLI share one validator.

**Tests (in this repo):** golden-file round-trips (import the real factory `image_manifest_v1` +
`rawprogram_unsparse0.xml` → model → re-export → byte/structural diff), sparse de-sparse vs
`simg2img`, signature pos/neg, JCS determinism, format-expansion subset correctness, erase/zero/patch
op emission, hash equivalence. These golden files come from the range-fetched real factory XMLs.

## The format: `particle_image_v1`

A single ZIP. **First entry `particle-image.json`** (the recipe). Remaining entries are per-partition
payloads **in flash order** (LUN1, LUN2, LUN4, LUN0, LUN5), optionally compressed (zstd/gzip) and
sparse/chunk-aware. Central directory still allows random-access single-slot extraction. Schema:

```jsonc
{
  "$schema": "https://linux-dist.particle.io/schema/particle_image_v1.json",
  "schema_version": 1,
  "release_name": "tachyon-ubuntu-24.04-NA-headless-1.2.0",
  "version": "1.2.0", "platform": "qcm6490", "board": "formfactor_dvt",
  "region": "NA", "variant": "headless",
  "distribution": "ubuntu", "distribution_version": "24.04",
  "sector_size": 4096,

  "format": {
    "kind": "factory",
    "emittable": ["factory","ota-image","ota-boot"],
    "slots_present": ["a","b"],
    "groups": {                        // labels sourced from partition_ext.xml
      "BOOT": ["xbl_a","xbl_config_a","xbl_b","xbl_config_b"],
      "FIRMWARE": ["uefi_a","tz_a","aop_a","hyp_a","dtb_a","cpucp_a", "...(_a/_b)"],
      "A": ["efi_a","system_a"], "B": ["efi_b","system_b"],
      "USER": ["userdata","persist"],
      "NVM": ["fsc","fsg","modemst1","modemst2","nvdata1","nvdata2"]
    }
  },

  "partitions": [                      // IN FLASH ORDER == zip entry order
    { "label":"system_a", "lun":0, "slot":"a", "role":"system", "group":"A",
      "size":21474836480, "start_sector":196608, "num_partition_sectors":5242880,
      "type_guid":"B921B045-...",
      "ops":[                          // ordered operation graph (the key addition)
        { "op":"erase" },              // blow the whole partition away first
        { "op":"program", "source":"system_a.simg.zst", "compression":"zstd",
          "sparse":true, "uncompressed_size":9876543210,
          "sha256":"<compressed entry>", "payload_sha256":"<expanded raw, holes=0>" }
      ],
      "signed":false, "image_id":null }
    // boot/firmware blobs carry signed=true + image_id; userdata/persist carry erase-only or nothing;
    // GPT carries {op:"gpt"} + {op:"patch", gptArith:[...]} entries
  ],

  "signing": {
    "profile":"test", "key_id":"particle-ota-2026",
    "algorithm":"ed25519", "digest_algorithm":"sha256",
    "canonicalization":"jcs",
    "signature":"base64(...)"          // ed25519 over JCS(manifest, signature="")
  }
}
```

Reconciled choices: **embedded** signature (JCS, blank-then-sign) so Python-free Node consumers all
verify identically; **ed25519 via native crypto**; **`payload_sha256` over the expanded-with-holes
raw image** so the on-device writer hashes-as-it-writes and delta can reproduce it by reading the
block device back (sparse decoder feeds zeros to the hasher while the writer seeks past holes). The
per-partition **`ops` array** is the addition that captures factory erase/zero + GPT patch math.

## Deliverable 1 — Composer: generate + validate (thin consumer)

- Keep `ptool`/`make_factory_img.sh` producing `rawprogram*/patch*` (incl. erase/wipe) as today.
- **New thin Node CLI `particle-image` (from the shared lib)**, invoked from `compose_24_04.sh`
  after `make_factory_img.sh` (~line 207): `particle-image generate --factory-dir $OUT/factory
  --partition-ext ... --image-map scripts/signing/image-map.tsv --emit factory|ota-image|ota-boot
  --slot a|b --sign-profile <p> --out <zip>`. It imports the factory tree into the model and emits
  `particle-image.json` + the manifest-first zip. Replaces the inline manifest heredoc; still also
  writes the legacy `manifest.json` (lib exports it) for back-compat.
- **Dockerfile:** add Node to the builder so the CLI runs in-container.
- **Makefile:** matrix targets `emit-factory`, `emit-ota-a`, `emit-ota-b`, `emit-ota-boot`, `validate`.

## Deliverable 2 — CI validator (thin consumer)

- `particle-image validate <zip|factory-dir>` (same binary, lib's `validate/`): manifest-first;
  ed25519 signature vs `keys/particle-ota-pub.pem`; per-partition `sha256`/`payload_sha256`; groups
  present (BOOT/FIRMWARE/A/B/NVM); **slot symmetry** (every `_a` has a `_b` peer, distinct type_guid,
  equal size, cross-checked vs `partition_ext.xml`); sizes fit; **all three formats emittable**;
  erase/zero ops present for factory. Non-zero exit + PASS/FAIL table. Gate release in CI.
- `keys/particle-ota-pub.pem` committed (test key); prod key mounted at CI time, never committed.

## Deliverable 3 — particle-cli (thin consumer; `../../cli/particle-cli`, main OK)

- **Depend on `particle-tachyon-image`**; delete any ad-hoc parsing in favour of the lib.
- `src/cmd/flash.js`/`src/cli/flash.js`: `--slot a|b`, `--format`, `--update full|slot|delta`
  (default `full`=today's full wipe → A/B-only incl. toggle → smart delta), `--emit-xml`
  (lib exports qdl rawprogram/patch from the model — "emit the XML manifest before flashing"),
  `--no-verify`, **`--dry-run`**. Payloads stream from the zip via `QdlFlasher`'s existing
  `--zip`/`--include`.
- **`--dry-run` (all flash/slot/update commands):** run the entire path — load + verify the manifest,
  expand the requested format/slot, build the qdl rawprogram/patch + GPT-attr ops, validate sizes
  against the device GPT — and **print the resulting plan** (partitions, ops, target slot, bytes)
  **without invoking `QdlFlasher`** or writing the device. This makes the whole feature exercisable
  with no hardware and is the primary "check all code runs" harness for the CLI.
- **New `src/cmd/slot-tachyon.js`** (`tachyon slot [a|b]`): GPT-attribute toggle. Reads device GPT
  via the existing `prepareFlashFiles`(read→`gpt_mainN.bin`)/`gpt` npm pattern, mutates the 64-bit
  `attr` bits (priority/active/success/unbootable/retry — positions per `ptool.py` + BP
  `PartitionTableUpdate.h`), reprograms primary+backup GPT via `generateXml({program})`+`QdlFlasher`.
- **New `src/cmd/update-tachyon.js`** (`tachyon update`): `slot` flashes one slot then optional
  `--toggle`; `delta` reads device GPT + on-device `payload_sha256` and writes only changed
  partitions. Reuses the lib's hash + format-expansion.
- Bundle `assets/keys/particle-ota-pub.pem`; unit tests for the CLI glue (lib carries the heavy tests).

## Deliverable 4 — On-device OTA service `particle-tachyon-ota` (thin consumer)

New repo, depends on `particle-tachyon-image`; mirrors particle-service structure (`src/`, `debian/`,
`.conf`). Runtime deps proven in particle-service (`dbus-native`, `execa`, `node-fetch`) + the lib.

- **dbus `io.particle.OtaService`** (system bus, `/io/particle/OtaService`, root-owned, exported via
  `dbus-native` like `particle-service/src/daemon.js`). Methods: `GetStatus`→`a{sv}`, `GetSlots`→
  `a{sv}`, `UpgradeFromFile(s)`→`s`, `UpgradeFromUrl(s)`→`s`, `CloneActiveToInactive()`→`s`,
  `CloneInactiveToActive()`→`s`, `SetActiveSlot(s)`→`s`, `MarkBootSuccessful()`→`s`, `Rollback()`→`s`,
  `Cancel(s)`→`s`, `GetLastResult()`→`a{sv}`. Properties (EmitsChange): `State`,`Progress`,
  `ActiveSlot`. Signals: `Progress(s u s)`, `JobStarted`, `JobFinished`, `VerificationFailed`,
  `SlotSwitched`. Interface shape modelled on the RIL vtable (`particle-tachyon-rild.c`).
- **Authorization:** `io.particle.OtaService.conf` (dbus policy, mirrors `io.particle.Particled.conf`)
  + `io.particle.ota.policy` (PolicyKit: `.inspect` open, `.upgrade`/`.slotcontrol` gated) + a
  `.rules` grant to the `particle` user so particle-service (controller) is authorized without a
  prompt. particle-service gains `src/ota-client.js` proxying cloud OTA commands.
- **Streaming apply (lib does the parsing/verify/decode):** open the zip as a stream (`node-fetch`
  body for URL; no whole-disk staging); entry 1 = manifest → buffer → `signing.verify` vs baked-in
  pubkey → reject before any write; target = **inactive** slot; reject any protected label
  (`persist`/`userdata`/NV/`misc`/...); then per partition run its `ops` in order against
  `/dev/disk/by-partlabel/<label>_<inactive>`: `erase` → `BLKDISCARD`/`blkdiscard` (or zero-fill
  fallback), `program` → `zipEntry→[gunzip]→sparse/chunk decode→hash→positioned block write`
  (seek past holes). Hash mismatch → abort, inactive slot left non-bootable. fsync per partition;
  never touch active slot/NV/persist/userdata.
- **Slot toggle (on booted device):** `sgdisk` (from `gdisk`) via `execa` over the live block device —
  set new slot active/priority/retry, clear unbootable, leave `success` pending; old slot stays as
  fallback. UEFI decrements retry per boot; `MarkBootSuccessful` (called by the boot-status oneshot
  on a healthy boot) sets `success`. Retry-exhaustion → automatic rollback. (Host CLI uses the `gpt`
  npm pkg over EDL instead — same bit semantics, different transport.)
- **Status every boot:** `ota-boot-status.service` (growfs oneshot pattern, no done-guard) logs
  slot/versions/health and calls `MarkBootSuccessful`.
- **Security:** baked-in public key at `/usr/share/particle/ota/particle-ota-pub.pem` (in both slots'
  rootfs); private key never on device; URL path runs the identical verify-then-write pipeline (no
  trust-TLS shortcut); daemon root + PolicyKit + systemd hardening.
- **Packaging:** new `tachyon-overlays/overlays/add-ota-service/` (models `overlays/particle-service`
  + `overlays/growfs`): `apt install -y gdisk`; install the `.deb`; copy units, dbus `.conf`, polkit
  `.policy`/`.rules`, pubkey; symlink into `multi-user.target.wants` (+ `ffbm.target.wants`).

## Deliverable 5 — Cloud server (thin consumer)

Wherever Particle's release/OTA server parses images: depend on `particle-tachyon-image` to parse +
validate uploaded `particle_image_v1` zips (manifest, signature, hashes, format capability) and to
expand/serve per-slot OTA-image subsets to devices. No image logic re-implemented server-side.

## Critical files
- **new repo `../particle-tachyon-image`** — `src/{model,manifest,xml,signing,hash,sparse,format,zip,validate}/`, `bin/particle-image`, full unit tests + golden files from the real factory XMLs.
- `tachyon-composer/compose_24_04.sh` (call `particle-image generate` ~line 207), `Dockerfile` (add Node), `Makefile` (emit/validate targets), `keys/particle-ota-pub.pem`.
- `cli/particle-cli` — depend on the lib; `src/cmd/slot-tachyon.js` (new), `src/cmd/update-tachyon.js` (new), `src/cmd/flash.js` + `src/cli/flash.js` + `src/cli/tachyon.js` (extend), `assets/keys/...pem`.
- **new repo `particle-tachyon-ota`** — `src/{daemon,iface,pipeline,slotctl,gpt,polkit,status}.js` (apply/parse via the lib), `debian/`, `io.particle.OtaService.conf`, `io.particle.ota.policy`.
- `tachyon-overlays/overlays/add-ota-service/` (new) + `particle-service/src/ota-client.js`.
- cloud server: add `particle-tachyon-image` dependency at its image-parse path.

## Risks / open items
- **Exact GPT attribute bit positions** must be confirmed against BP `PartitionTableUpdate.h` before
  the toggle is trusted on hardware — wrong bits brick slot selection.
- **`payload_sha256` over expanded-with-holes** must be implemented once in the lib and used by all
  consumers, or write-verify/delta never matches.
- **Erase semantics on a booted device:** UFS `<erase>`/unmap maps to `BLKDISCARD` on the live block
  device; confirm the kernel supports discard on these partitions, else zero-fill fallback.
- **Composer gains a Node dependency** in the builder image (new for a python/bash repo) — small but
  real; the alternative (re-implement the lib in Python) is exactly what the user wants to avoid.
- **Label reality:** kernel ships inside `system_*`; no `boot_a/b` in this layout — the manifest's
  partition list is authoritative; tooling only acts on labels that exist with an `_a/_b` sibling.
- **ed25519 cross-runtime determinism** (Node native here, since the lib is JS — composer calls the
  Node CLI, so no Python signer); verify with a fixture.

## Verification
1. **Lib unit tests** (gate everything): round-trip the **real** factory `image_manifest_v1` +
   `rawprogram_unsparse0.xml`/`patch0.xml` (range-fetched golden files) → model → re-export → diff;
   sparse round-trip vs `simg2img`; signature pos/neg; format-expansion subsets; erase/zero/patch
   emission; hash equivalence.
2. **Composer:** `make emit-factory emit-ota-a emit-ota-b emit-ota-boot`; assert manifest-first +
   payload order; `particle-image validate` over each; **diff a generated factory image's op graph
   against the downloaded real factory image** to confirm equivalent erase/zero/chunk behaviour.
3. **CLI:** mock `QdlFlasher`; `--slot a --format ota-image` rawprogram contains only `efi_a`/
   `system_a`; `tachyon slot b` flips the right `attr` bits; tampered payload → rejected before write.
4. **Device:** protected-label rejection; hash-mismatch aborts leaving inactive slot non-bootable;
   `sgdisk` attr round-trip on a loopback GPT; `BLKDISCARD` erase path.
5. **Hardware (Embroid `usb-flasher` + Linux `serial`):** flash factory baseline; `busctl
   introspect`/`monitor`; `UpgradeFromFile` a signed OTA-B zip → active slot untouched (sha256
   before/after) → slot switch + reboot → confirm booted slot; simulate failing boot → auto-rollback;
   `delta` on unchanged image writes zero partitions; `UpgradeFromUrl` streams with no full staging.
