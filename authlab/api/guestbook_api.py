from flask import request
from werkzeug.exceptions import BadRequest

import sqlite3

import authlab.core as core
from . import api_bp


@api_bp.get("/guestbook/messages")
def api_guestbook_list():
    """
    Return guestbook messages as JSON (newest first) with basic pagination.
    """
    user, resp = core.require_auth_json()
    if resp:
        return resp

    raw_limit = request.args.get("limit")
    raw_offset = request.args.get("offset")

    try:
        limit = core.parse_int(raw_limit, default=20, min_v=1, max_v=100)
        offset = core.parse_int(raw_offset, default=0, min_v=0, max_v=10_000)
    except ValueError as e:
        err_code = str(e)
        core.log_attempt(
            user, True, "api_guestbook", err_code,
            route=request.path,
            meta={"limit": raw_limit, "offset": raw_offset},
        )
        return core.api_error(err_code)

    with sqlite3.connect(core.DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()

        cur.execute("SELECT COUNT(*) AS c FROM guestbook_messages;")
        total = int(cur.fetchone()["c"])

        cur.execute(
            "SELECT id, ts, user, message FROM guestbook_messages "
            "ORDER BY id DESC LIMIT ? OFFSET ?;",
            (limit, offset),
        )
        items = [dict(r) for r in cur.fetchall()]

    payload = {
        "items": items,
        "count": len(items),
        "total": total,
        "offset": offset,
        "limit": limit,
    }
    core.log_attempt(
        user, True, "api_guestbook", "list",
        route=request.path, meta={"count": len(items), "total": total},
    )
    return core.json_ok(payload)


@api_bp.get("/guestbook/messages/<int:msg_id>")
def api_guestbook_detail(msg_id: int):
    """
    Return a single guestbook message by id.
    """
    user, resp = core.require_auth_json()
    if resp:
        return resp

    with sqlite3.connect(core.DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        cur.execute(
            "SELECT id, ts, user, message FROM guestbook_messages WHERE id = ? LIMIT 1;",
            (msg_id,),
        )
        row = cur.fetchone()
    if not row:
        core.log_attempt(
            user, True, "api_guestbook", "detail_not_found",
            route=request.path, meta={"id": msg_id},
        )
        return core.api_error("not_found")

    core.log_attempt(
        user, True, "api_guestbook", "detail_ok",
        route=request.path, meta={"id": msg_id},
    )
    return core.json_ok(dict(row))


@api_bp.post("/guestbook/messages")
def api_guestbook_create():
    """
    Create a guestbook entry via JSON body, protected with:
    - cookie auth (require_auth_json),
    - X-CSRF-Token header,
    - per-user rate-limit.
    """
    user, resp = core.require_auth_json()
    if resp:
        return resp

    if not core.require_csrf_header():
        core.log_attempt(user, True, "api_guestbook", "csrf_bad", route=request.path)
        return core.api_error("csrf_bad")

    rate_key = f"{core.API_GUESTBOOK_BUCKET}:{core.client_ip()}|{user.lower()}"

    allowed, retry_after = core.rl_check_and_hit(rate_key, core.WINDOW_SEC, core.MAX_ATTEMPTS)
    if not allowed:
        core.log_attempt(
            user, True, "api_guestbook", "ratelimited",
            route=request.path, meta={"retry_after": retry_after},
        )
        err = core.api_error("ratelimited")
        err.headers["Retry-After"] = str(retry_after)
        return err

    if not request.is_json:
        core.log_attempt(user, True, "api_guestbook", "bad_json", route=request.path)
        return core.api_error("bad_json")

    try:
        body = request.get_json() or {}
    except BadRequest:
        core.log_attempt(user, True, "api_guestbook", "invalid_json", route=request.path)
        return core.api_error("invalid_json")

    message = (body.get("message") or "").strip()
    if not message:
        core.log_attempt(user, True, "api_guestbook", "empty", route=request.path)
        return core.api_error("empty")

    if len(message) > core.MAX_MSG_LEN:
        message = message[: core.MAX_MSG_LEN]
    
    if "<" in message or ">" in message:
        core.log_attempt(
            user, True, "api_guestbook", "invalid_param",
            route=request.path, meta={"field": "message", "reason": "markup_not_allowed"},
        )
        return core.api_error("invalid_param")

    ts = core.now_utc_iso()

    with sqlite3.connect(core.DB_PATH) as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO guestbook_messages (ts, user, message) VALUES (?,?,?);",
            (ts, user, message),
        )
        conn.commit()
        new_id = cur.lastrowid

    rec = {"id": new_id, "ts": ts, "user": user, "message": message}

    core.log_attempt(
        user, True, "api_guestbook", "created",
        route=request.path, meta={"len": len(message), "id": rec["id"]},
    )

    resp = core.json_ok(rec, status=201)
    resp.headers["Location"] = f"/api/v1/guestbook/messages/{rec['id']}"
    return resp
