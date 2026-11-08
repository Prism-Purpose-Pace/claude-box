import http.server
import json
import sys


def sse(ev, data):
    return f"event: {ev}\ndata: {json.dumps(data)}\n\n".encode()


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        sys.stderr.write("REQ " + self.command + " " + self.path + "\n")

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        if "/messages" not in self.path:
            self.send_response(404)
            self.end_headers()
            return
        if "/count_tokens" in self.path:
            out = json.dumps({"input_tokens": 10}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        m = {
            "id": "msg_1",
            "type": "message",
            "role": "assistant",
            "model": body.get("model", "x"),
            "content": [],
            "stop_reason": None,
            "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }
        if not body.get("stream"):
            m["content"] = [{"type": "text", "text": "GATE-OK"}]
            m["stop_reason"] = "end_turn"
            out = json.dumps(m).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        w = self.wfile.write
        w(sse("message_start", {"type": "message_start", "message": m}))
        w(
            sse(
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
            )
        )
        w(
            sse(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": "GATE-OK"},
                },
            )
        )
        w(sse("content_block_stop", {"type": "content_block_stop", "index": 0}))
        w(
            sse(
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                    "usage": {"output_tokens": 2},
                },
            )
        )
        w(sse("message_stop", {"type": "message_stop"}))


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
