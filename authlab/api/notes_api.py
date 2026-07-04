import sqlite3
from urllib.parse import urlencode

from flask import request

import authlab.core as core
from . import api_bp


@api_bp.get("/notes")
def api_notes():
    """
    Return only the current user's notes with:
    - offset-based pagination,
    - whitelist sort (id|title),
    - RFC 5988 Link header (prev/next).
    """
    user, resp = core.require_auth_json()
    if resp:
        return resp

    rate_key = f"{core.API_NOTES_BUCKET}:{core.client_ip()}|{user.lower()}"
    allowed, retry_after = core.rl_check_and_hit(
        rate_key, core.WINDOW_SEC, core.MAX_ATTEMPTS
    )
    if not allowed:
        core.log_attempt(
            user, True, "api_notes", "ratelimited",
            route=request.path, meta={"retry_after": retry_after},
        )
        err = core.api_error("ratelimited")
        err.headers["Retry-After"] = str(retry_after)
        return err

    owner = user.lower()

    raw_limit = request.args.get("limit")
    raw_offset = request.args.get("offset")

    try:
        limit = core.parse_int(raw_limit, default=20, min_v=1, max_v=100)
        offset = core.parse_int(raw_offset, default=0, min_v=0, max_v=10_000)
    except ValueError as e:
        err_code = str(e)
        core.log_attempt(
            user, True, "api_notes", err_code,
            route=request.path,
            meta={"limit": raw_limit, "offset": raw_offset},
        )
        return core.api_error(err_code)

    sort_by_raw = (request.args.get("sort_by") or "title").lower()
    sort_dir_raw = (request.args.get("sort_dir") or "asc").lower()

    if sort_by_raw not in ("id", "title"):
        core.log_attempt(
            user, True, "api_notes", "invalid_sort_by",
            route=request.path, meta={"sort_by": sort_by_raw},
        )
        return core.api_error("invalid_sort_by")

    if sort_dir_raw not in ("asc", "desc"):
        core.log_attempt(
            user, True, "api_notes", "invalid_sort_dir",
            route=request.path, meta={"sort_dir": sort_dir_raw},
        )
        return core.api_error("invalid_sort_dir")
    
    COUNT_SQL = "SELECT COUNT(*) AS c FROM notes WHERE owner = ?;"

    PAGE_SQL = {
        ("id", "asc"):     "SELECT id, title FROM notes WHERE owner = ? ORDER BY id ASC LIMIT ? OFFSET ?;",
        ("id", "desc"):    "SELECT id, title FROM notes WHERE owner = ? ORDER BY id DESC LIMIT ? OFFSET ?;",
        ("title", "asc"):  "SELECT id, title FROM notes WHERE owner = ? ORDER BY title ASC, id ASC LIMIT ? OFFSET ?;",
        ("title", "desc"): "SELECT id, title FROM notes WHERE owner = ? ORDER BY title DESC, id ASC LIMIT ? OFFSET ?;",
    }

    page_sql = PAGE_SQL[(sort_by_raw, sort_dir_raw)]

    with sqlite3.connect(core.DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()

        cur.execute(COUNT_SQL, (owner,))
        row_count = cur.fetchone()
        total = int(row_count["c"]) if row_count else 0

        cur.execute(page_sql, (owner, limit, offset))
        items = [dict(r) for r in cur.fetchall()]

        qp = {
            "limit": limit,
            "sort_by": sort_by_raw,
            "sort_dir": sort_dir_raw,
        }
        links = []
        if offset > 0:
            prev_qp = dict(qp)
            prev_qp["offset"] = max(0, offset - limit)
            prev_url = f"/api/v1/notes?{urlencode(prev_qp)}"
            links.append(f'<{prev_url}>; rel="prev"')
        if offset + limit < total:
            next_qp = dict(qp)
            next_qp["offset"] = offset + limit
            next_url = f"/api/v1/notes?{urlencode(next_qp)}"
            links.append(f'<{next_url}>; rel="next"')

        resp_headers = {}
        if links:
            resp_headers["Link"] = ", ".join(links)

    core.log_attempt(
        user,
        True,
        "api_notes",
        "list",
        route=request.path,
        meta={
            "user": owner,
            "sort": f"{sort_by_raw}:{sort_dir_raw}",
            "limit": limit,
            "offset": offset,
            "count": len(items),
            "total": total,
        },
    )

    return core.json_ok(
        {
            "items": items,
            "count": len(items),
            "total": total,
            "offset": offset,
            "limit": limit,
        },
        headers=resp_headers,
    )

@api_bp.get("/notes/<int:note_id>")
def api_notes_detail(note_id: int):
    """
    Return a single note owned by the current user.
    Non-existent or foreign notes are masked behind the same JSON 404.
    """
    user, resp = core.require_auth_json()
    if resp:
        return resp
    
    rate_key = f"{core.API_NOTES_BUCKET}:{core.client_ip()}|{user.lower()}"
    allowed, retry_after = core.rl_check_and_hit(
        rate_key, core.WINDOW_SEC, core.MAX_ATTEMPTS
    )
    if not allowed:
        core.log_attempt(
            user, True, "api_notes", "ratelimited_detail",
            route=request.path, meta={"retry_after": retry_after},
        )
        err = core.api_error("ratelimited")
        err.headers["Retry-After"] = str(retry_after)
        return err

    owner = user.lower()

    with sqlite3.connect(core.DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        query = (
            "SELECT id, title, body FROM notes "
            "WHERE id = ? AND owner = ? LIMIT 1;"
        )
        params = (note_id, owner)
        cur.execute(query, params)
        row = cur.fetchone()

    if not row:
        core.log_attempt(
            user, True, "api_notes", "detail_masked_404",
            route=request.path, meta={"note_id": note_id},
        )
        return core.api_error("not_found")

    data = {"id": row["id"], "title": row["title"], "body": row["body"]}
    core.log_attempt(
        user, True, "api_notes", "detail_ok",
        route=request.path, meta={"note_id": note_id},
    )
    return core.json_ok(data)
