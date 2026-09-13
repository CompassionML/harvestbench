"""URI read/write and logging helpers shared by the Coworld roles.

Same shape as the Paint Arena example the Coworld package ships: every
artifact location arrives as a URI (`file://`, bare path, or presigned
HTTP(S)); logs go to stdout and, when `COGAME_LOG_URI` is set, are also
POSTed line by line so the hosted runner can collect them.
"""

from __future__ import annotations

import atexit
import logging
import os
import sys
from logging.handlers import QueueHandler, QueueListener
from pathlib import Path
from queue import SimpleQueue
from typing import Literal, cast
from urllib.parse import urlparse
from urllib.request import Request, url2pathname, urlopen

# urllib's default User-Agent is blocked by some CDN rules; any other suffices.
HTTP_USER_AGENT = "coworld-harvestbench/0.1"
JSON = "application/json"


def local_path(uri: str) -> Path | None:
    """The filesystem path a URI names, or None for a remote URI. Accepts
    bare paths (a Windows drive letter is not a scheme) and file:// URIs
    (url2pathname maps /C:/x to the Windows drive path and leaves POSIX alone)."""
    parsed = urlparse(uri)
    if parsed.scheme == "file":
        return Path(url2pathname(parsed.path))
    if parsed.scheme in ("http", "https"):
        return None
    return Path(uri)


def read_data(uri: str) -> bytes:
    path = local_path(uri)
    if path is not None:
        return path.read_bytes()
    request = Request(uri, headers={"User-Agent": HTTP_USER_AGENT})
    with urlopen(request, timeout=60) as response:
        return response.read()


def artifact_method(env_var: str) -> Literal["POST", "PUT"]:
    method = os.environ.get(env_var, "PUT").upper()
    if method not in {"POST", "PUT"}:
        raise ValueError(f"{env_var} must be PUT or POST")
    return cast(Literal["POST", "PUT"], method)


def write_data(uri: str, data: bytes | str, *, content_type: str = JSON,
               http_method: Literal["POST", "PUT"] = "PUT") -> None:
    if isinstance(data, str):
        data = data.encode("utf-8")
    path = local_path(uri)
    if path is None:
        request = Request(uri, data=data, method=http_method)
        request.add_header("Content-Type", content_type)
        request.add_header("User-Agent", HTTP_USER_AGENT)
        with urlopen(request, timeout=120):
            return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(data)
    tmp.replace(path)  # atomic publish, as the game contract asks


class _HttpLogHandler(logging.Handler):
    def __init__(self, url: str) -> None:
        super().__init__()
        self.url = url

    def emit(self, record: logging.LogRecord) -> None:
        message = self.format(record)
        print(message, flush=True)
        try:
            request = Request(self.url, data=message.encode(), method="POST")
            request.add_header("Content-Type", "text/plain")
            request.add_header("User-Agent", HTTP_USER_AGENT)
            with urlopen(request, timeout=10):
                pass
        except Exception:
            self.handleError(record)


def get_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)
    if logger.handlers:
        return logger
    logger.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(name)s %(levelname)s %(message)s")
    url = os.environ.get("COGAME_LOG_URI")
    if url:
        queue: SimpleQueue[logging.LogRecord] = SimpleQueue()
        handler = _HttpLogHandler(url)
        handler.setFormatter(fmt)
        listener = QueueListener(queue, handler)
        listener.start()
        atexit.register(listener.stop)
        logger.addHandler(QueueHandler(queue))
    else:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(fmt)
        logger.addHandler(handler)
    logger.propagate = False
    return logger
