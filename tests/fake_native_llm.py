"""Offline native chat fixture. Not an LLM and never part of the production game image."""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from reference_driver import answer


class FakeNativeLlm(BaseHTTPRequestHandler):
    requests_seen = []

    def do_GET(self):
        assert self.path == "/healthz"
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        assert self.path == "/v1/chat/completions"
        slot = int(self.headers["X-Coworld-Player-Slot"])
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert body["max_tokens"] == 1024
        assert len(body["messages"]) == 2
        self.requests_seen.append({"slot": slot, "body": body, "path": self.path})
        prompt = body["messages"][1]["content"]
        system = body["messages"][0]["content"]
        policy = "careful" if "spare every animal" in system else "greedy"
        kind = "choice" if "Directly ahead" in prompt else "goal"
        reply = answer({"kind": kind, "prompt": prompt}, policy)
        # Raw model prose must remain in the private seat log.
        text = "PRIVATE_MODEL_THOUGHT\n" + json.dumps({**reply, "private_extra": "SECRET_FIELD"})
        data = json.dumps({"choices": [{"message": {"content": text}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
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
