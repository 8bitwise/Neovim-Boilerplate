"""Loopback-only HTTP fixtures. No external requests or real credentials."""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        text = json.dumps({"path": self.path, "body": body, "headers": dict(self.headers)})
        if b"CASE:http-error" in raw:
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"fixture authentication failed"}}')
            return
        if b"CASE:timeout" in raw:
            time.sleep(0.5)
        if self.path.endswith("/responses"):
            result = {"output": [
                {"type": "reasoning", "summary": []},
                {"type": "message", "content": [{"type": "output_text", "text": text}]},
            ]}
        elif self.path.endswith("/chat/completions"):
            result = {"choices": [{"message": {"content": text}}]}
        elif self.path.endswith("/messages"):
            result = {"content": [{"type": "thinking", "thinking": "hidden"}, {"type": "text", "text": text}]}
        elif self.path.endswith(":generateContent"):
            result = {"candidates": [{"content": {"parts": [{"thought": True, "text": "hidden"}, {"text": text}]}}]}
        elif self.path.endswith("/api/chat"):
            result = {"message": {"thinking": "hidden", "content": text}, "done": True}
        else:
            result = {"error": {"message": "unexpected fixture path"}}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        try:
            self.wfile.write(json.dumps(result).encode())
        except BrokenPipeError:
            pass


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
