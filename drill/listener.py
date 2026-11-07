"""Stand-in for the alert webhook and the dead-man's switch during the drill.

Logs one line per request, "<METHOD> <path> <first 200 chars of the body>", to
stdout, so drill/run.sh can read what arrived with `docker compose logs`.
It only listens on the Compose network and is removed when the drill ends.
"""

from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def _log_and_answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        body = " ".join(body.split())[:200]
        print(f"{self.command} {self.path} {body}".rstrip(), flush=True)
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"OK")

    do_GET = do_POST = _log_and_answer

    def log_message(self, *args):  # silence the default access log
        pass


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
