# tachyon-composer 迁移到新 BP — 设计方案

日期: 2026-06-19  状态: 待 review

## 目标

让 tachyon-composer 产出 **新 BP 工厂镜像**(QCM6490 Quectel bp-fw r108 / 2.0.0,**UEFI 启动链**),
复用 composer 现有的 rootfs/efi/overlay 前端,把"启动 + 分区组装"后端换成
tachyon-eugene 已在硬件上验证过的那一套(ptool + partition_ext + bootbinaries + dtb_a + core_nhlos)。

## 策略:替换后端(不保留旧 U-Boot 路径)

- **保留**:composer 的 rootfs.ext4 构建(24.04 base + tachyon-overlay-tool)、versions.json / Makefile / Docker 机制。
- **替换**:启动链 + 分区表 → eugene 的 `ptool.py` + `partition_ext.xml` + `QCM6490_bootbinaries` + `dtb_a` + `core_nhlos`。
- **删除**:`xbl.elf` 打 U-Boot 补丁、`qtestsign` 签名、`.dtbo`→`/boot/overlays`、`rawprogram*.xml` 就地改 size/filename 那套。

旧 BP 是 U-Boot 引导;新 BP 是 UEFI 直引导(uefi_a 来自 bootbinaries),分区多了 `dtb_a` / `core_nhlos_a`,
分区表由 ptool 生成,所以是大改而非小补。

## 组件来源(已定稿)

| 组件 (分区) | 来源 | 方式 |
|---|---|---|
| **system** (rootfs.ext4) | composer 自造(24.04 base + overlay),overlay stack 补新 BP 挂载 | 保留 |
| **efi** (efi.img) | 从 eugene 搬运的 vendored GRUB(`BOOTAA64.EFI` + `grub.cfg`) | vendor + 构建 |
| **dtb_a** (dtb.img) | kernel deb 取 **`qcm6490-tachyon.dtb`**(不是 combined-dtb.dtb!)→ FAT16 `make-dtb-img.sh` | 取 + 打包 |
| **core_nhlos_a** (nonhlos-<region>.img) | 从 eugene 搬运的 vendored region 固件 blob(em/na)+ `make-nonhlos_img.sh` | vendor + 构建 |
| **bootbinaries / QCM6490_fw** | S3 永久 release `https://tachyon-ci.particle.io/release/tachyon-bp-fw-2.0.0.zip` | fetch |
| **kernel** | S3 永久 release `https://linux-dist.particle.io/kernel/release/stable-6.8.0-1058.59particle2/` | fetch(composer 已有机制) |
| **组装** (ptool/partition_ext/provision/cdt.bin) | 从 eugene 搬运 | vendor |

> 关键纠正:dtb_a 里的文件名叫 `combined-dtb.dtb` 只是 **EDK2/UEFI 从该分区读的固定名**;内容必须是 Tachyon 单板
> `qcm6490-tachyon.dtb`。kernel Makefile 那个 `combined-dtb.dtb`(多参考板 `*-ovl.dtb` 拼接)与 Tachyon 无关,不能用。

## 新 compose 流程

```
1) rootfs.ext4   ← composer:24.04 base + overlay-tool(stack 加新 BP 挂载/新 kernel)
2) efi.img       ← vendored GRUB(make-efi-img.sh)
3) dtb.img       ← kernel deb 提 qcm6490-tachyon.dtb → FAT16 make-dtb-img.sh
4) nonhlos-em.img← vendored blobs(make-nonhlos_img.sh --variant em)
5) bootbins+fw   ← fetch bp-fw 2.0.0,拆成 QCM6490_bootbinaries.zip + QCM6490_fw.zip
                   (QCM6490_fw 进 rootfs overlay;bootbinaries 给组装)
6) assemble      ← ptool + partition_ext.xml → rawprogram*/patch*,打包成 EDL 可刷 zip
```

## 仓库改动(文件级)

**新增(从 eugene 搬运,vendor):**
- `assemble/` : `ptool.py`, `config/partition_ext.xml`, `config/provision_ufs22.xml`, `cdt.bin`, `make_factory_img.sh`
- `nonhlos/`  : `em/` `na/` 固件 blob + `make-nonhlos_img.sh`
- `efi/`      : `EFI/BOOT/BOOTAA64.EFI`, `grub.cfg`, `make-efi-img.sh`
- dtb 处理脚本: 从 kernel deb 取 `qcm6490-tachyon.dtb` + `make-dtb-img.sh`(FAT16)

**改:**
- `versions.json` : 加 `bp_fw`(S3 2.0.0)、`kernel` 指向 `stable-6.8.0-1058.59particle2`;去掉 `tachyon-u-boot`
- `Makefile` / compose 脚本 : 删 bootloader/dtbo 段,接新组装管线(产出 5 路 → ptool)
- overlay stack : 加 nonhlos/dtb 挂载 + msm blacklist(参考 eugene `tachyon-console` stack)

**删:**
- `compose_24_04.sh` 中 patchxbl/qtestsign/efi-from-base/dtbo 段;u-boot fetch 相关 Make 目标

## 验证(Stage 1)

- 先 **单 region(em ≈ RoW)**,复用 composer 现有 rootfs。
- 本地 `make` 出 factory zip → `particle flash --tachyon ...` 烧录 → 进 console。
- 通过后再扩 NA/RoW × headless/desktop 矩阵。

## 待办 / 风险

1. **kernel deb 依赖**:`stable-6.8.0-1058.59particle2` 的 CI 构建跑完后,确认 modules deb 内含 `qcm6490-tachyon.dtb`,再接 dtb 这步。
2. **rootfs 启动适配**:composer 现有 rootfs 是按 U-Boot 启动设计的;换 UEFI/新 BP 后能否启动需实测,可能要调 kernel cmdline / fstab / 挂载点。
3. **efi 取舍**:确认 vendored GRUB 与 composer 现有"从 24.04 base EFI rsync"二选一(本方案用 vendored GRUB)。
4. NA/RoW × variant 矩阵、region 映射(RoW→em / NA→na)留后续。
