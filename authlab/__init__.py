from flask import Flask, request, session
from werkzeug.exceptions import HTTPException

import authlab.core as core
from authlab.core import SECRET_KEY, api_error, json_err, log_attempt
from authlab.health import health_bp
from authlab.api import api_bp
from authlab.web import web_bp

API_PREFIX = "/api/v1"


def create_app():
    app = Flask(__name__)
    app.config["SECRET_KEY"] = SECRET_KEY
    app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
    app.config["SESSION_COOKIE_HTTPONLY"] = True

    app.register_blueprint(health_bp)
    app.register_blueprint(api_bp, url_prefix=API_PREFIX)
    app.register_blueprint(web_bp)

    @app.after_request
    def _security_headers(resp):
        resp.headers.setdefault("X-Content-Type-Options", "nosniff")

        # do not touch API responses
        if request.path.startswith(API_PREFIX):
            return resp

        content_type = resp.headers.get("Content-Type", "")
        if not content_type.startswith("text/html"):
            return resp

        resp.headers.setdefault("X-Frame-Options", "DENY")
        resp.headers.setdefault("Referrer-Policy", "no-referrer")

        if (
            request.path in {"/login", "/mfa", "/dashboard", "/guestbook", "/notes", "/logout"}
            or request.path.startswith("/note/")
        ):
            resp.headers["Cache-Control"] = "no-store, max-age=0"
            resp.headers["Pragma"] = "no-cache"
            resp.headers["Expires"] = "0"

        # keep XSS teaching surfaces exploitable in poc mode
        if request.path == "/search" and core.XSS_R_STATE == "poc":
            return resp

        if request.path == "/guestbook" and core.XSS_S_STATE == "poc":
            return resp

        resp.headers.setdefault(
            "Content-Security-Policy",
            "default-src 'self'; "
            "style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; "
            "object-src 'none'; "
            "base-uri 'self'; "
            "form-action 'self'; "
            "frame-ancestors 'none'"
        )

        return resp

    # API: normalize all HTTP errors into JSON envelope
    @app.errorhandler(HTTPException)
    def _http_error(e):
        if not request.path.startswith(API_PREFIX):
            return e

        code = e.code or 500

        if code == 401:
            return api_error("unauthorized")

        if code == 404:
            return api_error("not_found")

        if code == 405:
            resp = api_error("method_not_allowed")
            allow = getattr(e, "valid_methods", None)
            if allow:
                resp.headers["Allow"] = ", ".join(sorted(allow))
            return resp

        # Other HTTP errors -> keep JSON envelope too
        return json_err("http_error", e.name or "HTTP error", status=code)

    # API: unexpected crashes -> JSON 500 + log
    @app.errorhandler(Exception)
    def _unexpected(e):
        if not request.path.startswith(API_PREFIX):
            raise

        user = session.get("user")
        log_attempt(
            user,
            bool(user),
            "api_error",
            "server_error",
            route=request.path,
            meta={"type": type(e).__name__},
        )
        return api_error("server_error")

    return app