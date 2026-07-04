from flask import request, session

import authlab.core as core
from . import api_bp


@api_bp.post("/auth/session")
def api_session_create():
    """
    Create/refresh an API session (DEV bootstrap).

    Accepts:
      - existing cookie session (already authenticated), OR
      - DEV_MODE + Authorization: Bearer <DEV_API_KEY> (lab-only bootstrap)

    Returns JSON:
      { "user": "...", "csrf_token": "..." }
    """
    user, resp = core.require_auth_bootstrap_json()
    if resp:
        return resp

    rate_key = f"{core.API_AUTH_BUCKET}:{core.client_ip()}|{user.lower()}"
    allowed, retry_after = core.rl_check_and_hit(rate_key, core.WINDOW_SEC, core.MAX_ATTEMPTS)
    if not allowed:
        core.log_attempt(
            user, True, "api_session_create", "ratelimited",
            route=request.path, meta={"retry_after": retry_after},
        )
        err = core.api_error("ratelimited")
        err.headers["Retry-After"] = str(retry_after)
        err.headers["Cache-Control"] = "no-store"
        return err

    session["user"] = user

    token = core.ensure_csrf_token()
    data = {"user": user, "csrf_token": token}

    core.log_attempt(user, True, "api_session_create", "ok", route=request.path, meta=None)

    out = core.json_ok(data)
    out.headers["Cache-Control"] = "no-store"
    return out


@api_bp.get("/auth/session")
def api_session_status():
    """
    Read current API session (introspection only).
    """
    user = session.get("user")
    if not user:
        out = core.api_error("unauthorized")
        out.headers["Cache-Control"] = "no-store"
        return out

    token = session.get("csrf_token")
    if not token:
        core.log_attempt(user, True, "api_session_status", "bootstrap_required", route=request.path, meta=None)
        out = core.api_error("bootstrap_required")
        out.headers["Cache-Control"] = "no-store"
        return out

    data = {"user": user}

    core.log_attempt(user, True, "api_session_status", "ok", route=request.path, meta=None)

    out = core.json_ok(data)
    out.headers["Cache-Control"] = "no-store"
    return out
