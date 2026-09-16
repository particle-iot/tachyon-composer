#!/usr/bin/env bash
# Checkout only: build-sdk.sh and build-runtime-rpms.sh use separate workspaces.
set -euo pipefail
config=$(realpath "${1:?composer versions.json}")
workspace=${2:?Yocto workspace}
project=$(cd "$(dirname "$0")/../.." && pwd)
[[ $(uname -s) = Linux && $(uname -m) = x86_64 ]] || { echo 'QLI build requires Linux x86_64' >&2; exit 1; }
command -v kas >/dev/null
mkdir -p "$workspace"
workspace=$(realpath "$workspace")
python3 "$project/scripts/qli/checkout.py" "$config" yocto "$workspace/meta-qcom-releases"
python3 - "$config" "$workspace/meta-qcom-releases/lock.yml" <<'PY'
import hashlib,json,pathlib,sys
expected=json.load(open(sys.argv[1]))['yocto']['lock_sha256']
if hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest()!=expected:
    raise SystemExit('QLI lock checksum mismatch')
PY
cd "$workspace"
kas checkout meta-qcom-releases/lock.yml
cp meta-qcom-releases/lock.yml meta-qcom/ci/lock.yml
