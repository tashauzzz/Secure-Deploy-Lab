import secrets

import pyotp
from flask import (
    render_template,
    request,
    redirect,
    url_for,
    session,
    make_response,
)
from werkzeug.security import check_password_hash

from authlab import core
from authlab.web import web_bp

@web_bp.get("/login")
def login_get():
    """
    Render the login form.

    Ensures a CSRF token is present in the session and passes it to the template.
    """
    token = core.ensure_csrf_token()
    return render_template("login.html", csrf_token=token)

@web_bp.post("/login")
def login_post():
    """
    Handle login form submission.

    Flow:
    1. CSRF check.
    2. Rate-limit before user lookup.
    3. Password check.
    4. If MFA enabled - redirect to /mfa, otherwise log in and go to dashboard.
    """
    username = (request.form.get("username") or "").strip().lower()
    password = request.form.get("password") or ""
    password_stripped = password.strip()

    form_csrf = request.form.get("csrf_token")
    sess_csrf = session.get("csrf_token")
    if (
        not form_csrf
        or not sess_csrf
        or not secrets.compare_digest(form_csrf, sess_csrf)
    ):
        core.log_attempt(username, False, "invalid", "csrf_bad", route=request.path)
        new_token = secrets.token_hex(32)
        session["csrf_token"] = new_token
        return (
            render_template("login.html", error="Invalid session", csrf_token=new_token),
            400,
        )

    if not username:
        core.log_attempt(username, False, "invalid", "empty_username", route=request.path)
        return (
            render_template(
                "login.html",
                error="Username required",
                csrf_token=session["csrf_token"],
            ),
            400,
        )

    if not password_stripped:
        core.log_attempt(username, False, "invalid", "empty_password", route=request.path)
        return (
            render_template(
                "login.html",
                error="Password required",
                csrf_token=session["csrf_token"],
            ),
            400,
        )

    rate_key = f"{core.RATE_BUCKET}:{core.client_ip()}|{(username or '_')}"
    allowed, retry_after = core.rl_check_and_hit(
        rate_key,
        core.WINDOW_SEC,
        core.MAX_ATTEMPTS,
    )
    if not allowed:
        core.log_attempt(username, False, "invalid", "ratelimited", route=request.path, meta={"retry_after": retry_after},)
        resp = make_response(
            render_template(
                "login.html",
                error="Invalid session",
                csrf_token=session.get("csrf_token"),
            ),
            429,
        )  
        resp.headers["Retry-After"] = str(retry_after)
        return resp

    user = core.USERS.get(username)
    if not user:
        core.log_attempt(username, False, "invalid", "no_user", route=request.path)
        return (
            render_template(
                "login.html",
                error="Invalid credentials",
                csrf_token=session["csrf_token"],
            ),
            401,
        )

    if not check_password_hash(user["password_hash"], password):
        core.log_attempt(username, True, "invalid", "bad_password", route=request.path)
        return (
            render_template(
                "login.html",
                error="Invalid credentials",
                csrf_token=session["csrf_token"],
            ),
            401,
        )

    if user["mfa_enabled"]:
        session["pending_user"] = username
        core.log_attempt(username, True, "mfa_required", "-", route=request.path)
        return redirect(url_for("web.mfa_get"))

    session.clear()
    session["user"] = username
    core.log_attempt(username, True, "success", "-", route=request.path)
    return redirect(url_for("web.dashboard"))

@web_bp.get("/mfa")
def mfa_get():
    """
    Render MFA form for a user who passed the password step.

    The username is stored in session["pending_user"] after /login.
    """
    pending_user = session.get("pending_user")
    if not pending_user:
        return redirect(url_for("web.login_get"))

    token = core.ensure_csrf_token()
    return render_template("mfa.html", csrf_token=token, error=None)

@web_bp.post("/mfa")
def mfa_post():
    """
    Handle MFA verification.

    Flow:
    1. CSRF check.
    2. Rate-limit by username+IP.
    3. Verify TOTP code.
    4. On success - clear session and set session["user"].
    """
    pending_user = session.get("pending_user")
    if not pending_user:
        return redirect(url_for("web.login_get"))
    
    form_csrf = request.form.get("csrf_token")
    sess_csrf = session.get("csrf_token")
    if (
        not form_csrf
        or not sess_csrf
        or not secrets.compare_digest(form_csrf, sess_csrf)
    ):
        core.log_attempt(pending_user, True, "invalid", "csrf_bad", route=request.path)
        new_token = secrets.token_hex(32)
        session["csrf_token"] = new_token
        return (
            render_template(
                "mfa.html",
                error="Invalid session",
                csrf_token=new_token,
            ),
            400,
        )

    rate_key = f"{core.MFA_BUCKET}:{core.client_ip()}|{pending_user.lower()}"
    allowed, retry_after = core.rl_check_and_hit(
        rate_key,
        core.WINDOW_SEC,
        core.MAX_ATTEMPTS,
    )
    if not allowed:
        core.log_attempt(pending_user, True, "invalid", "ratelimited", route=request.path, meta={"retry_after": retry_after},)
        resp = make_response(
            render_template(
                "mfa.html",
                error="Invalid session",
                csrf_token=session.get("csrf_token"),
            ),
            429,
        )
        resp.headers["Retry-After"] = str(retry_after)
        return resp

    user = core.USERS.get(pending_user)
    if not user or not user.get("mfa_enabled") or not user.get("mfa_secret"):
        session.pop("pending_user", None)
        return redirect(url_for("web.login_get"))

    code = (request.form.get("code") or "").strip()
    ok = False
    if code and code.isdigit():
        totp = pyotp.TOTP(user["mfa_secret"])
        ok = totp.verify(code, valid_window=core.MFA_WINDOW)

    if ok:
        session.clear()
        session["user"] = pending_user
        core.log_attempt(pending_user, True, "success", "mfa_ok", route=request.path)
        return redirect(url_for("web.dashboard"))

    core.log_attempt(pending_user, True, "invalid", "mfa_bad", route=request.path)
    new_token = secrets.token_hex(32)
    session["csrf_token"] = new_token
    return (
        render_template(
            "mfa.html",
            error="Invalid one-time code",
            csrf_token=new_token,
        ),
        401,
    )

@web_bp.get("/dashboard")
def dashboard():
    """
    Simple dashboard after login.

    Requires an authenticated session and reuses ensure_csrf_token()
    for any state-changing forms on the page.
    """
    user = session.get("user")
    if not user:
        return redirect(url_for("web.login_get"))
    token = core.ensure_csrf_token()
    return render_template("dashboard.html", user=user, csrf_token=token)

@web_bp.post("/logout")
def logout():
    """
    Logout endpoint with CSRF protection.

    If CSRF fails, the user stays on the dashboard and receives a new token.
    """
    user = session.get("user")
    if not user:
        return redirect(url_for("web.login_get"))
    
    form_csrf = request.form.get("csrf_token")
    sess_csrf = session.get("csrf_token")

    if (
        not form_csrf
        or not sess_csrf
        or not secrets.compare_digest(form_csrf, sess_csrf)
    ):
        core.log_attempt(user, True, "invalid", "csrf_bad", route=request.path)
        new_token = secrets.token_hex(32)
        session["csrf_token"] = new_token
        return (
            render_template(
                "dashboard.html",
                user=user,
                csrf_token=new_token,
                error="Invalid session",
            ),
            400,
        )

    core.log_attempt(user, True, "logout", "ok", route=request.path)
    session.clear()
    return redirect(url_for("web.login_get"))

@web_bp.get("/")
def index():
    """Redirect the site root to the login page."""
    return redirect(url_for("web.login_get"))
