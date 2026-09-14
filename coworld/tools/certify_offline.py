"""Certify the file-player contract against a deterministic fake Converse server.

The production manifest and game image are never modified. Hosted upload still
runs certification with real model calls through the platform sidecar.
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

manifest_path = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[2]
manifest = json.loads(manifest_path.read_text())
image = "harvestbench-coworld-test:offline-certification"
subprocess.run([
    "docker", "build", "--build-arg", f"GAME_IMAGE={manifest['game']['runnable']['image']}",
    "-f", str(root / "coworld/Dockerfile.test"), "-t", image, str(root),
], check=True)
with tempfile.TemporaryDirectory(prefix="harvestbench-offline-cert-") as directory:
    package = Path(directory) / "package"
    shutil.copytree(manifest_path.parent, package)
    manifest["game"]["runnable"]["image"] = image
    manifest["game"]["runnable"]["run"] = ["python", "tests/fake_bedrock.py"]
    offline_manifest = package / manifest_path.name
    offline_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    subprocess.run([
        "coworld", "certify", str(offline_manifest), "--timeout-seconds", "120", "--no-open-report",
    ], check=True)
