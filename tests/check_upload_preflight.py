"""Run the actual upload CLI with real local preflight, without publishing.

Only the authentication boundary is replaced. Cold-cache certification must
run the release image and seat files; a second upload must reuse that proof.
"""

import hashlib
import os
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

from typer.testing import CliRunner

import coworld.upload as upload
from coworld.cli import app
from coworld.runner.bedrock_sidecar_wiring import RESERVED_SIDECAR_APP_ENV


class UploadBoundaryReached(Exception):
    """Stop immediately before credentials, image uploads or API writes."""


manifest = Path(sys.argv[1]).resolve()
before = hashlib.sha256(manifest.read_bytes()).hexdigest()
assert "AWS_ENDPOINT_URL_BEDROCK_RUNTIME" in RESERVED_SIDECAR_APP_ENV
runner = CliRunner()
with tempfile.TemporaryDirectory(prefix="harvestbench-preflight-cache-") as cache:
    with (
        patch.dict(os.environ, {"XDG_CACHE_HOME": cache}),
        patch.object(upload, "certify_coworld", wraps=upload.certify_coworld) as certify,
        patch.object(upload.CoworldUploadClient, "from_login", side_effect=UploadBoundaryReached) as authenticate,
    ):
        for attempt in (1, 2):
            result = runner.invoke(app, [
                "upload-coworld", str(manifest), "--timeout-seconds", "120", "--wait-certification",
            ])
            print(result.output)
            assert isinstance(result.exception, UploadBoundaryReached), repr(result.exception)
            assert authenticate.call_count == attempt
            assert certify.call_count == 1, "Cold preflight must run; unchanged warm preflight must be cached"
            assert hashlib.sha256(manifest.read_bytes()).hexdigest() == before
            print(f"Upload preflight {attempt}/2 passed; stopped before authentication and publication.")
