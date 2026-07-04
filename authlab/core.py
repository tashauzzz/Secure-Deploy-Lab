import os
import json
import time
import secrets
from datetime import datetime

from flask import (request, session, jsonify)

# --- .env autoload (dev convenience) ---

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

# --- Secrets from environment ---

ADMIN_PWHASH = os.getenv("ADMIN_PWHASH")
if not ADMIN_PWHASH:
    raise RuntimeError("ADMIN_PWHASH is not set (provide it via environment)")

SECRET_KEY = os.getenv("SECRET_KEY")
if not SECRET_KEY:
    raise RuntimeError("SECRET_KEY is not set (provide it via environment)")

# --- Authlab DB path ---

DB_PATH = os.getenv("DB_PATH")
if not DB_PATH:
    raise RuntimeError("DB_PATH is not set (provide it via environment)")

# --- API error catalog ---

API_ERRORS = {
    "unauthorized": ("Login required", 401),
    "bootstrap_required": ("Call POST /auth/session first", 409),
    "csrf_bad": ("Invalid CSRF token", 400),
    "bad_json": ("Expected application/json", 415),
    "invalid_json": ("Invalid JSON body", 400),
    "empty": ("Message required", 400),
    "ratelimited": ("Too many requests", 429),
    "invalid_param": ("Bad parameter", 400),
    "invalid_range": ("Invalid range", 400),
    "invalid_sort_by": ("Invalid sort_by", 400),
    "invalid_sort_dir": ("Invalid sort_dir", 400),
    # + for global handlers:
    "not_found": ("Resource not found", 404),
    "method_not_allowed": ("Method not allowed", 405),
    "server_error": ("Internal server error", 500),
}
API_AUTH_BUCKET = os.getenv("API_AUTH_BUCKET", "api_auth")
API_GUESTBOOK_BUCKET = os.getenv("API_GUESTBOOK_BUCKET", "api_guestbook")
API_PRODUCTS_BUCKET = os.getenv("API_PRODUCTS_BUCKET", "api_products")
API_NOTES_BUCKET = os.getenv("API_NOTES_BUCKET", "api_notes")

# --- Rate-Limit config (fixed-window) ---

WINDOW_SEC  = int(os.getenv("WINDOW_SEC", 60))
MAX_ATTEMPTS = int(os.getenv("MAX_ATTEMPTS", 5))
RATE_BUCKET = os.getenv("RATE_BUCKET", "default")
RATE_STATE  = {}  # rate_key - {"start": int, "count": int}

# --- Web Guestbook rate-limit (separate bucket) ---

WEB_GUESTBOOK_BUCKET = os.getenv("WEB_GUESTBOOK_BUCKET", "web_guestbook")
WEB_GUESTBOOK_WINDOW_SEC = int(os.getenv("WEB_GUESTBOOK_WINDOW_SEC", str(WINDOW_SEC)))
WEB_GUESTBOOK_MAX_ATTEMPTS = int(os.getenv("WEB_GUESTBOOK_MAX_ATTEMPTS", str(MAX_ATTEMPTS)))

# --- Web Notes rate-limit ---

WEB_NOTES_BUCKET = os.getenv("WEB_NOTES_BUCKET", "web_notes")
WEB_NOTES_WINDOW_SEC = int(os.getenv("WEB_NOTES_WINDOW_SEC", 10))
WEB_NOTES_MAX_ATTEMPTS = int(os.getenv("WEB_NOTES_MAX_ATTEMPTS", 30))


# --- MFA config ---

ADMIN_MFA_ENABLED = (os.getenv("ADMIN_MFA_ENABLED", "false").lower() == "true")
ADMIN_MFA_SECRET  = os.getenv("ADMIN_MFA_SECRET")
MFA_WINDOW        = int(os.getenv("MFA_WINDOW", 1))
MFA_BUCKET        = os.getenv("MFA_BUCKET", "login_mfa")

if ADMIN_MFA_ENABLED and not ADMIN_MFA_SECRET:
    raise RuntimeError("ADMIN_MFA_ENABLED=true, but ADMIN_MFA_SECRET is missing")

# --- Users (store only hashes) ---

USERS = {
    "admin": {
        "password_hash": ADMIN_PWHASH,
        "mfa_enabled":  ADMIN_MFA_ENABLED,
        "mfa_secret":   ADMIN_MFA_SECRET,
    }
}

# --- Toggles ---

def read_lab_state(name, default="safe"):
    """Read and validate a lab state toggle: safe or poc."""
    value = os.getenv(name, default).lower().strip()
    if value not in {"safe", "poc"}:
        raise RuntimeError(f"{name} must be 'safe' or 'poc'")
    return value

XSS_R_STATE = read_lab_state("XSS_R_STATE")  # reflected: poc|safe
XSS_S_STATE = read_lab_state("XSS_S_STATE")  # stored: poc|safe
SQLI_STATE  = read_lab_state("SQLI_STATE")   # sqli: poc|safe
IDOR_STATE  = read_lab_state("IDOR_STATE")   # idor: poc|safe

DEV_MODE = os.getenv("DEV_MODE", "false").lower() == "true"

# --- Guestbook config ---

MAX_MSG_LEN = int(os.getenv("MAX_MSG_LEN", 500))

# --- Logs ---

# Container-native logging:
# In hardened/deploy mode, write structured logs to stdout so Docker/Kubernetes
# can collect them without requiring a writable /app/logs directory.

LOG_TO_STDOUT = os.getenv("LOG_TO_STDOUT", "false").lower() == "true"

LOG_DIR = os.getenv("LOG_DIR", "logs")
LOG_FILE = os.path.join(LOG_DIR, "authlab.log")

if not LOG_TO_STDOUT:
    os.makedirs(LOG_DIR, exist_ok=True)


def now_utc_iso():
    """Return current UTC time in ISO8601 with Z suffix."""
    return datetime.utcnow().isoformat() + "Z"


def client_ip():
    """Best-effort client IP from Flask request."""
    return request.remote_addr or "-"


def log_attempt(username, user_exists, result, reason, route=None, meta=None):
    """Write one structured authlab log record to file or stdout."""
    rec = {
        "ts": now_utc_iso(),
        "ip": client_ip(),
        "username": username,
        "user_exists": bool(user_exists),
        "result": result,
        "reason": reason,
        "route": route,
        "meta": meta,
    }

    line = json.dumps(rec, ensure_ascii=False)

    if LOG_TO_STDOUT:
        print(line, flush=True)
        return

    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(line + "\n")

# --- Rate-limit helper (fixed window) ---

def rl_check_and_hit(rate_key, window_sec, max_attempts, now=None):
    """
    Fixed-window rate limit.

    Returns (allowed: bool, retry_after_seconds: int).
    If allowed=False - retry_after_seconds >= 1, attempt is NOT counted.
    If allowed=True  - attempt already counted (count++).
    """
    if now is None:
        now = int(time.time())

    state = RATE_STATE.get(rate_key)
    if state is None or now >= state["start"] + window_sec:
        state = {"start": now, "count": 0}
        RATE_STATE[rate_key] = state

    if state["count"] >= max_attempts:
        retry_after = (state["start"] + window_sec) - now
        if retry_after < 1:
            retry_after = 1
        return False, retry_after

    state["count"] += 1
    return True, 0

def json_ok(data, status=200, headers=None):
    """Uniform successful JSON response."""
    resp = jsonify(data)
    resp.status_code = status
    if headers:
        for k, v in headers.items():
            resp.headers[k] = v
    return resp

def json_err(code, message, status=400, details=None, headers=None):
    """Unified error JSON: { error: { code, message, details } }."""
    body = {"error": {"code": code, "message": message}}
    if details is not None:
        body["error"]["details"] = details
    resp = jsonify(body)
    resp.status_code = status
    if headers:
        for k, v in headers.items():
            resp.headers[k] = v
    return resp

def api_error(code, details=None):
    """Shortcut to build an error from API_ERRORS catalog."""
    msg, status = API_ERRORS[code]
    return json_err(code, msg, status=status, details=details)

def parse_int(raw, *, default=None, min_v=None, max_v=None):
    """Strict integer parser for API parameters"""
    if raw in (None, ""):
        value = default
    else:
        try:
            value = int(str(raw).strip())
        except (TypeError, ValueError):
            raise ValueError("invalid_param")

    if value is None:
        raise ValueError("invalid_param")

    if min_v is not None and value < min_v:
        raise ValueError("invalid_range")

    if max_v is not None and value > max_v:
        raise ValueError("invalid_range")

    return value


def parse_float_or_none(val):
    """Parse float or return None on empty/invalid."""
    if val is None or val == "":
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None
    
def require_auth_json():
    """
    Cookie-only auth for API endpoints.

    Returns (user, None) on success or (None, error_response).
    """
    user = session.get("user")
    if user:
        return user, None
    return None, api_error("unauthorized")


def require_auth_bootstrap_json():
    """
    Bootstrap auth for POST /api/v1/auth/session only.
    """
    user = session.get("user")
    if user:
        return user, None

    auth = request.headers.get("Authorization", "")

    if (
        DEV_MODE
        and request.path == "/api/v1/auth/session"
        and request.method == "POST"
    ):
        dev_key = os.getenv("DEV_API_KEY")
        if dev_key and auth.startswith("Bearer "):
            supplied = auth[7:].strip()
            if secrets.compare_digest(supplied, dev_key):
                log_attempt(
                    "admin",
                    True,
                    "api_auth",
                    "dev_api_key",
                    route=request.path,
                    meta=None,
                )
                return "admin", None

    log_attempt(
        "-",
        False,
        "api_auth",
        "bootstrap_failed",
        route=request.path,
        meta={
            "auth_header": bool(auth),
            "bearer": auth.startswith("Bearer "),
            "dev_mode": DEV_MODE,
        },
    )

    err = api_error("unauthorized")
    err.headers["Cache-Control"] = "no-store"
    return None, err

def ensure_csrf_token():
    """
    Ensure session['csrf_token'] exists (create if missing).

    Shared between HTML and API.
    """
    token = session.get("csrf_token")
    if not token:
        token = secrets.token_hex(32)
        session["csrf_token"] = token
    return token

def require_csrf_header():
    """
    For JSON writes require X-CSRF-Token == session['csrf_token'].
    No side-effects: does NOT create missing csrf_token.
    """
    expected = session.get("csrf_token")
    if not expected:
        return False

    provided = request.headers.get("X-CSRF-Token")
    if not provided:
        return False

    return secrets.compare_digest(provided, expected)