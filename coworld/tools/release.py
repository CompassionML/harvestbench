"""Certify and optionally upload the real game with a local model service.

Local Docker honors the manifest's AWS_ENDPOINT_URL_BEDROCK_RUNTIME. Hosted
episodes discard that reserved override and inject the platform sidecar URL.
The exact manifest certified here is passed to upload, without changing the
game image, its entrypoint, the bundled souls, or certification cache records.
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("manifest", type=Path)
parser.add_argument("--upload", action="store_true", help="Upload and wait for real hosted certification.")
parser.add_argument("--check-upload-preflight", action="store_true",
                    help="Exercise cold/warm upload preflight, stopping before authentication or remote writes.")
args = parser.parse_args()
manifest_path = args.manifest.resolve()
root = Path(__file__).resolve().parents[2]
manifest = json.loads(manifest_path.read_text())
name = "harvestbench-preflight-" + uuid.uuid4().hex[:12]
image = name + ":model-service"

subprocess.run([
    "docker", "build", "--build-arg", f"GAME_IMAGE={manifest['game']['runnable']['image']}",
    "-f", str(root / "coworld/Dockerfile.test"), "-t", image, str(root),
], check=True)

# coworld 0.1.47's local runner puts its game container on this network.
# The service has a unique DNS name and exposes no host port.
network = "coworld-local"
inspected = subprocess.run(["docker", "network", "inspect", network], capture_output=True)
if inspected.returncode != 0:
    subprocess.run(["docker", "network", "create", network], check=True)
container = subprocess.check_output([
    "docker", "run", "--detach", "--rm", "--name", name, "--network", network,
    "--cpus", "1", "--memory", "256m",
    "--health-cmd", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8081/healthz')\"",
    "--health-interval", "1s", "--health-timeout", "2s", "--health-retries", "20",
    image, "python", "tests/fake_bedrock.py",
], text=True).strip()
try:
    deadline = time.monotonic() + 30
    while True:
        health = subprocess.check_output([
            "docker", "inspect", "--format", "{{.State.Health.Status}}", container,
        ], text=True).strip()
        if health == "healthy":
            break
        if health == "unhealthy" or time.monotonic() >= deadline:
            raise RuntimeError("Local model service did not become healthy")
        time.sleep(0.5)

    with tempfile.TemporaryDirectory(prefix="harvestbench-release-") as directory:
        package = Path(directory) / "package"
        shutil.copytree(manifest_path.parent, package)
        # This is a documented local runtime override. The hosted dispatcher
        # filters reserved AWS endpoint variables before injecting its sidecar.
        game_env = manifest["game"]["runnable"].setdefault("env", {})
        game_env["AWS_ENDPOINT_URL_BEDROCK_RUNTIME"] = f"http://{name}:8081"
        release_manifest = package / manifest_path.name
        release_manifest.write_text(json.dumps(manifest, indent=2) + "\n")

        if args.check_upload_preflight:
            subprocess.run([
                sys.executable, str(root / "tests/check_upload_preflight.py"), str(release_manifest),
            ], check=True)
        subprocess.run([
            "coworld", "certify", str(release_manifest), "--timeout-seconds", "120", "--no-open-report",
        ], check=True)
        if args.upload:
            subprocess.run([
                "coworld", "upload-coworld", str(release_manifest),
                "--timeout-seconds", "120", "--wait-certification",
            ], check=True)
finally:
    subprocess.run(["docker", "rm", "--force", container], check=True)
