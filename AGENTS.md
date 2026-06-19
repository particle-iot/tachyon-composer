# AGENTS.md

Development conventions and guidance for AI assistants (Codex / Claude / Copilot, etc.)
working in this repository.

Scope: **the entire repository**.

---

## 1. Project overview (for quick onboarding)

- This project is the **Tachyon System Image Composer**: a Docker-based build system that
  produces an **EDL-flashable factory image** for the **new BP** (Quectel r108 / QCM6490,
  **UEFI boot chain**), per region (`NA`/`RoW`) and variant (`headless`/`desktop`).
- Key files:
  - `Makefile`: the main entry point. Orchestrates parameter validation, the Docker build,
    fetching build assets (24.04 base rootfs, bp-fw, kernel deb, overlay tool + overlays),
    and invoking the compose script.
  - `compose_24_04.sh`: the compose script executed **inside the Docker container**. It
    builds `rootfs.ext4` (from the 24.04 base + overlay stack), `efi.img`, `dtb.img` and
    `nonhlos.img`, then assembles them into an EDL-flashable image with `ptool` +
    `partition_ext`.
  - `build-efi/`: vendored GRUB ESP (`BOOTAA64.EFI`, `grub.cfg`) + `make-efi-img.sh`.
  - `build-dtb/`: `build-dtb.sh` (extracts `qcm6490-tachyon.dtb` from the kernel deb) +
    `make-dtb-img.sh` (FAT16 dtb image).
  - `build-nonhlos/`: per-region modem/BT firmware blobs (`em/`, `na/`) + `make-nonhlos_img.sh`.
  - `assemble/`: `ptool.py`, `cdt.bin`, `config/partition_ext.xml`, `config/provision_ufs22.xml`,
    `make_factory_img.sh` — the partition layout + image assembly backend.
  - `versions.json`: the authoritative source-versions and env-pin file.
  - `Dockerfile`: builds the builder image used to run the flow above.
- For more background and usage, prefer:
  - `README.md`
  - `BUILDING.md`
  - `CLAUDE.md`

> Note: this composer was migrated from the legacy 20.04→24.04 *upgrade* tool (U-Boot /
> `xbl.elf` / `qtestsign` / `rawprogram` editing) to the new-BP UEFI backend. The legacy
> `prepare_base_24.04.sh` and `xml_tools.py` no longer exist; do not reintroduce that path.

---

## 2. General working principles

- **Small, focused changes**: each change should solve a single, well-defined problem;
  avoid large refactors.
- **Keep the CLI interface stable**:
  - Do not casually change the meaning of arguments or the output format of existing targets
    such as `make build_24.04`, `make help`, `make version`.
  - When adding parameters/behavior, keep old usage working or provide a clear migration path.
- **Respect existing structure and style**:
  - Shell scripts: follow the style of `compose_24_04.sh` (`set -euo pipefail`, the shared
    `section` printer, clear error output).
  - Makefile: keep the existing section comments, variable naming, `.PHONY` declarations and
    indentation (use TABs).
  - Python: the vendored `ptool.py` is upstream Qualcomm tooling — avoid editing it; keep any
    new helper tools to the Python 3 standard library.
- **Avoid unnecessary dependencies**:
  - Prefer the existing toolchain (bash, coreutils, python3, jq, curl, zip/unzip, mtools,
    dosfstools, e2fsprogs).
  - If a dependency is truly required, declare it centrally in the `Dockerfile` and consider
    image size and security.
- **Do not commit build artifacts**:
  - Anything under `.tmp/`, extracted images, and generated `.zip` files are temporary/output
    and must not be version-controlled.

---

## 3. Per-file-type conventions

### 3.1 Makefile

- Keep the existing layout (parameter definitions, validation, fetch targets, compose, Docker
  targets).
- Reuse existing helper macros (e.g. `check_required_param`, `validate_region`,
  `validate_variant`) instead of copy-pasting new implementations.
- When changing **version-parsing logic** or **Docker-related variables**, make sure:
  - `make version` still derives a semantic version (`x.y.z`) from the git tag.
  - Target/variable names that CI or scripts depend on are not broken (e.g. `build_24.04`,
    `docker/build`, `fetch_*`).

### 3.2 Shell scripts (`.sh`)

- Use `#!/usr/bin/env bash` as the shebang.
- Start with `set -euo pipefail`. Gate `set -x` behind the `DEBUG` argument; never enable
  tracing by default on the production path.
- Prefer small functions (e.g. the existing `section` pattern).
- On error, print enough context (current directory, key paths, external command output),
  consistent with the existing scripts.
- Steps that fan out to external tools (overlay apply, dtb/nonhlos/efi builders, ptool) MUST
  **fail loud** — propagate non-zero exit and abort the build. Do not let a subshell swallow
  a failure (this previously caused the overlay step to silently no-op).
- When using `sudo`, loop devices or mounts, reuse the approach already in `compose_24_04.sh`.

### 3.3 Dockerfile

- When changing the base image or installed packages:
  - Bump the top-of-file `# particle-dockerfile-version=` comment so external tooling and CI
    can track the image version.
  - Avoid adding non-essential tools; keep the image lean.
- Keep the non-root `builder` user model and the `/project` working directory. Any root-only
  work belongs in the build stage, not at runtime.

---

## 4. Build & verification guidance

> Note: a full 24.04 image build downloads several large files (~12GB total). Run it only when
> necessary.

- Lightweight checks:
  - `make help` — confirm new targets/parameters appear correctly.
  - `make doctor` — check host Docker, git and QEMU arm64 emulation.
- Docker-related changes:
  - `make docker/build` — confirm the builder image builds.
- Representative build (slow, disk-heavy):
  ```bash
  make build_24.04 \
    VERSIONS_FILE=./versions.json \
    INPUT_REGION=RoW \
    INPUT_VARIANT=headless \
    DEBUG=true
  ```
- Iterating on the compose logic:
  - `make docker/shell` to enter the container, then run `./compose_24_04.sh ...` directly.

---

## 5. Versioning & release notes

- The repo version (git tag, e.g. `1.2.3`) is the version of the generated system image. Do
  not change the semantic-versioning rules arbitrarily.
- When changing version output or tag parsing, ensure `make version` behaves the same locally
  and in CI, and do not break version-string assumptions in CI/CD.
- The kernel/dtb and rootfs versions are governed by `versions.json` (see `BUILDING.md` §3 and
  the new-BP handoff). Changing them can break the `check-pinned-packages` overlay — keep the
  rootfs kernel pin (`PKG_linux_particle`) consistent with the chosen 24.04 base.

---

## 6. Documentation & collaboration habits

- For any change that affects how the tool is used (command parameters, output filenames,
  build flow), update:
  - `README.md` (user-facing docs)
  - `BUILDING.md` (step-by-step build guide)
  - this `AGENTS.md`, if a convention itself needs to change.
- When adding a new tool/script, include a short header comment describing its purpose, inputs
  and outputs, and use a clear, consistent filename.

Unless stated otherwise, follow the conventions above. If a higher-priority instruction (e.g. a
direct request from the user in conversation) conflicts with this file, the higher-priority
instruction wins — but try to stay within these constraints.
