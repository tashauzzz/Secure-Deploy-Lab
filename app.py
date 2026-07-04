#!/usr/bin/env python3

import os
from authlab import create_app
from werkzeug.serving import WSGIRequestHandler


app = create_app()


class NoServerHeaderRequestHandler(WSGIRequestHandler):
    def send_response(self, code, message=None):
        self.log_request(code)
        self.send_response_only(code, message)
        self.send_header("Date", self.date_time_string())


def get_port():
    """Read and validate the HTTP port from environment."""
    raw_port = os.getenv("PORT", "5000").strip()

    try:
        port = int(raw_port)
    except ValueError:
        raise SystemExit(f"Invalid PORT value: {raw_port!r}")

    if port < 1 or port > 65535:
        raise SystemExit(f"PORT out of range: {port} (expected 1-65535)")

    return port


if __name__ == "__main__":
    host = os.getenv("HOST", "127.0.0.1")
    port = get_port()

    dev_mode = os.getenv("DEV_MODE", "false").lower().strip() == "true"
    flask_debug = os.getenv("FLASK_DEBUG", "false").lower().strip() == "true"

    debug = dev_mode and flask_debug

    app.run(
        host=host,
        port=port,
        debug=debug,
        use_reloader=debug,
        request_handler=NoServerHeaderRequestHandler,
    )