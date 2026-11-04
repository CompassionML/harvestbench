"""Offline native chat fixture. Not an LLM and never part of the production game image."""

import base64
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4

from reference_driver import answer


class FakeNativeLlm(BaseHTTPRequestHandler):
    requests_seen = []
    raw_requests_seen = []
    responses_written = []
    include_private_extra = True
    private_extra_first_only = False
    emit_identity_headers = False

    def do_GET(self):
        assert self.path == "/healthz"
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        self.raw_requests_seen.append(
            {
                "path": self.path,
                "body_b64": base64.b64encode(raw).decode(),
                "slot_header": self.headers.get("X-Coworld-Player-Slot"),
                "platform_call_id": None,
            }
        )
        assert self.path == "/v1/chat/completions"
        slot = int(self.headers["X-Coworld-Player-Slot"])
        body = json.loads(raw)
        assert body["max_tokens"] == 1024
        assert len(body["messages"]) == 2
        self.requests_seen.append({"slot": slot, "body": body, "path": self.path})
        prompt = body["messages"][1]["content"]
        system = body["messages"][0]["content"]
        policy = "careful" if "spare every animal" in system else "greedy"
        kind = "choice" if "Directly ahead" in prompt else "goal"
        reply = answer({"kind": kind, "prompt": prompt}, policy)
        # Raw model prose must remain in the private seat log.
        extra = {"private_extra": "SECRET_FIELD"} if self.include_private_extra else {}
        if self.private_extra_first_only and len(self.requests_seen) > 1:
            extra = {}
        text = "PRIVATE_MODEL_THOUGHT\n" + json.dumps({**reply, **extra})
        data = json.dumps({"choices": [{"message": {"content": text}}]}).encode()
        # Explicit opt-in test transport identities are NOT signed receipts.
        identity_headers = []
        if self.emit_identity_headers:
            call_id = str(uuid4())
            identity_headers = [
                ("X-Softmax-Llm-Call-Id", call_id),
                ("X-Request-Id", "local-fixture-" + str(len(self.requests_seen))),
            ]
        self.send_response(200)
        for key, value in identity_headers:
            self.send_header(key, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        written = self.wfile.write(data)
        self.wfile.flush()
        self.responses_written.append(
            {
                "body_b64": base64.b64encode(data).decode(),
                "socket_write_return": written,
                "native_received_proven": False,
                "synthetic_identity_headers": identity_headers,
            }
        )

    def log_message(self, format: str, *_args: object) -> None:
        pass


def start_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeNativeLlm)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


if __name__ == "__main__":
    # Separate local service for the production image's preflight. No test
    # code or model implementation is copied into the uploaded game image.
    ThreadingHTTPServer(("0.0.0.0", 8081), FakeNativeLlm).serve_forever()
