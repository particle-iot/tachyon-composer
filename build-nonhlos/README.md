# make-nonhlos-img

This directory contains a self-contained tool to build `nonhlos.img`.

## Input

- `QCM6490_fw.zip`

## Usage

```bash
tools/make-nonhlos-img/make-nonhlos_img.sh \
  --fwzip /path/to/QCM6490_fw.zip \
  --output /path/to/nonhlos.img
```

If `--output` is not specified, the default output path is `./nonhlos.img`.

## Behavior

- create a new empty FAT32 image
- create `/QCM6490_fw` in the image root
- unzip `QCM6490_fw.zip`
- copy the unzipped contents into `/QCM6490_fw`

## Image Size

- fixed size: `174080 KiB`
