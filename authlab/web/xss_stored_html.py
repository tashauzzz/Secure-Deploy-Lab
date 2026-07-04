import secrets
import sqlite3

from flask import (
    render_template,
    request,
    redirect,
    url_for,
    session,
    make_response,
)

from authlab import core
from authlab.web import web_bp

@web_bp.get("/guestbook")
def guestbook_get():
    """Render guestbook with stored XSS surface."""
    user = session.get("user")
    if not user:
        return redirect(url_for("web.login_get"))

    token = core.ensure_csrf_token()

    with sqlite3.connect(core.DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        cur.execute(
            "SELECT id, ts, user, message FROM guestbook_messages "
            "ORDER BY id DESC LIMIT 200;"
        )
        messages = cur.fetchall()

    reason = "stored_poc" if core.XSS_S_STATE == "poc" else "stored_safe"
    core.log_attempt(
        user,
        True,
        "xss_surface",
        reason,
        route=request.path,
        meta={"count": len(messages)},
    )
    return render_template(
        "guestbook.html",
        messages=messages,
        csrf_token=token,
        state=core.XSS_S_STATE,
        max_len=core.MAX_MSG_LEN,
    )

@web_bp.post("/guestbook")
def guestbook_post():
    """Handle guestbook POST, intentionally storing raw input."""
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

        with sqlite3.connect(core.DB_PATH) as conn:
            conn.row_factory = sqlite3.Row
            cur = conn.cursor()
            cur.execute(
                "SELECT id, ts, user, message FROM guestbook_messages "
                "ORDER BY id DESC LIMIT 200;"
            )
            messages = cur.fetchall()

        return (
            render_template(
                "guestbook.html",
                messages=messages,
                csrf_token=new_token,
                state=core.XSS_S_STATE,
                error="Invalid session",
                max_len=core.MAX_MSG_LEN,
            ),
            400,
        )
    rate_key = f"{core.WEB_GUESTBOOK_BUCKET}:{core.client_ip()}|{user.lower()}"
    allowed, retry_after = core.rl_check_and_hit(
        rate_key,
        core.WEB_GUESTBOOK_WINDOW_SEC,
        core.WEB_GUESTBOOK_MAX_ATTEMPTS,
    )
    if not allowed:
        core.log_attempt(user, True, "invalid", "ratelimited", route=request.path,
                         meta={"retry_after": retry_after})
        with sqlite3.connect(core.DB_PATH) as conn:
            conn.row_factory = sqlite3.Row
            cur = conn.cursor()
            cur.execute(
                "SELECT id, ts, user, message FROM guestbook_messages "
                "ORDER BY id DESC LIMIT 200;"
            )
            messages = cur.fetchall()
            
        resp = make_response(
            render_template(
                "guestbook.html",
                messages=messages,
                csrf_token=session.get("csrf_token"),
                state=core.XSS_S_STATE,
                error="Invalid session",
                max_len=core.MAX_MSG_LEN,
            ),
            429,
        )
        resp.headers["Retry-After"] = str(retry_after)
        return resp

    message = (request.form.get("message") or "").strip()
    if not message:
        token = core.ensure_csrf_token()
        with sqlite3.connect(core.DB_PATH) as conn:
            conn.row_factory = sqlite3.Row
            cur = conn.cursor()
            cur.execute(
                "SELECT id, ts, user, message FROM guestbook_messages "
                "ORDER BY id DESC LIMIT 200;"
            )
            messages = cur.fetchall()
        return (
            render_template(
                "guestbook.html",
                messages=messages,
                csrf_token=token,
                state=core.XSS_S_STATE,
                error="Message required",
                max_len=core.MAX_MSG_LEN,
            ),
            400,
        )

    if len(message) > core.MAX_MSG_LEN:
        message = message[: core.MAX_MSG_LEN]
        
    if core.XSS_S_STATE != "poc" and ("<" in message or ">" in message):
        token = core.ensure_csrf_token()
        with sqlite3.connect(core.DB_PATH) as conn:
            conn.row_factory = sqlite3.Row
            cur = conn.cursor()
            cur.execute(
                "SELECT id, ts, user, message FROM guestbook_messages "
                "ORDER BY id DESC LIMIT 200;"
            )
            messages = cur.fetchall()

        core.log_attempt(
            user,
            True,
            "xss_surface",
            "stored_safe_reject_markup",
            route=request.path,
            meta={"len": len(message)},
        )

        return (
            render_template(
                "guestbook.html",
                messages=messages,
                csrf_token=token,
                state=core.XSS_S_STATE,
                error="Markup is not allowed in safe mode",
                max_len=core.MAX_MSG_LEN,
            ),
            400,
        )

    with sqlite3.connect(core.DB_PATH) as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO guestbook_messages (ts, user, message) VALUES (?,?,?);",
            (core.now_utc_iso(), user, message),
        )
        conn.commit()
    core.log_attempt(
        user,
        True,
        "xss_surface",
        "stored_raw",
        route=request.path,
        meta={"len": len(message)},
    )

    return redirect(url_for("web.guestbook_get"))