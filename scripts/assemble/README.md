# make-factory-img

This directory contains a self-contained UFS packaging tool. It does not depend on any other directory in the repository.

## Inputs

- `QCM6490_bootbinaries.zip`
- partition images passed as `--<partition_name> /path/to/file`

## Usage

```bash
tools/make-factory-img/make_factory_img.sh \
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
- `provision_ufs22.xml`
- `rawprogram0.xml` through `rawprogram5.xml`
- `patch0.xml` through `patch5.xml`
- `gpt_main*`, `gpt_backup*`, `gpt_both*`, and `gpt_empty*`

## Notes

- The script copies `partition_ext.xml` into the output directory and updates `filename=` for every partition label passed on the command line.
- Partition names must match `label=` values in `partition_ext.xml` exactly.
- If a partition label appears multiple times in `partition_ext.xml`, every matching entry is updated.
