# Signing keys

This folder holds the **signing key material** used by `scripts/signing/` to sign the boot/firmware
blobs of the Tachyon system image.

## ⚠️ DO NOT CHECK IN ANYTHING BUT TEST KEYS ⚠️

**Only stock, non-secret Qualcomm TEST keys may be committed to this repository.**

Production / proprietary / OEM keys **must never** be committed. They are supplied at build time
via a secret or mounted path (e.g. CI secret, bind mount) and resolved by `scripts/signing/sign.sh`
when `signing.profile = prod`. See `scripts/signing/README.md`.

If you are about to `git add` a key here, stop and ask: *is this a stock test key?* If not, it does
not belong in git.

## What's here

- `qti_presigned_certs-key2048_exp257_hashSHA384/` — the stock Qualcomm **TEST** cert config. It is
  the default key named by `versions.json` → `signing.key` for `profile = test`. Note: with
  sectoolsv2 `--signing-mode TEST` the built-in test keys are used, so this material is effectively
  vestigial today — it is retained as the named selectable key and the template for the `prod`
  swap. It provides **no** production security and is for development/bring-up only.

## How a key is selected

`versions.json`:

```json
"signing": {
  "profile": "test",
  "key": "qti_presigned_certs-key2048_exp257_hashSHA384"
}
```

- `profile = test` → `scripts/signing` resolves the key from `./keys/<signing.key>/` (this folder).
- `profile = prod` → `scripts/signing` resolves the key from the build-time secret path instead
  (never from this folder, never from git).

## `.gitignore` guard

`keys/.gitignore` ignores everything by default and re-includes only the known test cert config and
this README, so a stray `git add keys/` cannot accidentally commit private key material.
