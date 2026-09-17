"""One-off stable promotion. This branch is for execution, not merging."""
import argparse
import copy
import json
import os
from pathlib import Path
import re
from urllib.request import Request, urlopen

from tachyon_dist_tools import json_validator, s3_updater

TARGET = "1.2.26"
EXPECTED = "1.2.24"
KEY = "meta/tachyon-stable.json"
ROWS = {(region, variant, "formfactor_dvt") for region in ("NA", "RoW")
        for variant in ("desktop", "headless")}


def is_24(build):
    return build["distribution"] == "ubuntu" and build["distribution_version"] == "24.04"


def validate_matrix(builds, version):
    if len(builds) != 4 or {(b["region"], b["variant"], b["board"]) for b in builds} != ROWS:
        raise ValueError("Expected exactly NA/RoW x desktop/headless for formfactor_dvt")
    if any(not is_24(b) or b["version"] != version for b in builds):
        raise ValueError(f"Expected only Ubuntu 24.04 {version}")


def plan_promotion(stable, target):
    schemas = json_validator.get_default_schema_folder()
    for document in (stable, target):
        json_validator.validate_json(document, schemas)
    validate_matrix(target["builds"], TARGET)
    for build in target["builds"]:
        artifacts = build.get("artifacts", [])
        if len(artifacts) != 1 or artifacts[0].get("type") != "release_image":
            raise ValueError("Expected one release ZIP per build")
        artifact = artifacts[0]
        if not re.fullmatch(r"[a-f0-9]{64}", artifact.get("sha256_checksum", "")):
            raise ValueError("Missing or invalid SHA-256")
        prefix = f"https://linux-dist.particle.io/releases/{TARGET}/{build['region']}/"
        if not artifact["artifact_url"].startswith(prefix) or not artifact["artifact_url"].endswith(".zip"):
            raise ValueError("Artifact is not from the pinned published release")
    current = [b for b in stable["builds"] if is_24(b)]
    canonical = lambda builds: sorted(json.dumps(b, sort_keys=True) for b in builds)
    if canonical(current) == canonical(target["builds"]):
        return copy.deepcopy(stable)
    validate_matrix(current, EXPECTED)
    proposed = copy.deepcopy(stable)
    proposed["builds"] = [b for b in proposed["builds"] if not is_24(b)] + copy.deepcopy(target["builds"])
    json_validator.validate_json(proposed, schemas)
    return proposed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    bucket = os.environ["LINUX_DIST_S3_BUCKET"]
    output = Path("promotion")
    output.mkdir(exist_ok=True)
    before_path = output / "stable-before.json"
    target_path = output / "release-1.2.26.json"
    after_path = output / "stable-proposed.json"
    transaction = output / "stable-transaction.json"
    s3_updater.read_s3_object(bucket, KEY, str(before_path), str(transaction))
    s3_updater.read_s3_object(bucket, f"meta/tachyon-{TARGET}.json", str(target_path), str(output / "target-transaction.json"))
    before = json.loads(before_path.read_text())
    target = json.loads(target_path.read_text())
    proposed = plan_promotion(before, target)
    after_path.write_text(json.dumps(proposed, indent=2) + "\n")
    for build in target["builds"]:
        with urlopen(Request(build["artifacts"][0]["artifact_url"], method="HEAD"), timeout=60) as response:
            if response.status != 200:
                raise ValueError("Release ZIP is unavailable")
        print(f"Verified published ZIP: {build['region']} {build['variant']} {TARGET}")
    if proposed == before:
        print("Stable already matches the pinned release; no write needed")
    elif args.apply:
        # The ETag belongs to the exact stable document validated above. Abort on
        # a concurrent change instead of overwriting another promotion.
        s3_updater.write_s3_object(bucket, KEY, str(after_path), str(transaction))
        print(f"Promoted Ubuntu 24.04 stable: {EXPECTED} -> {TARGET}")
    else:
        print("Dry run: no metadata written")


if __name__ == "__main__":
    main()
