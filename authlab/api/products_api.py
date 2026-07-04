import sqlite3
from urllib.parse import urlencode

from flask import request

import authlab.core as core
from . import api_bp


@api_bp.get("/products")
def api_products_list():
    """
    Case-insensitive search, price range filters, whitelisted sort, pagination,
    and RFC 5988 Link headers.
    """
    user, resp = core.require_auth_json()
    if resp:
        return resp

    rate_key = f"{core.API_PRODUCTS_BUCKET}:{core.client_ip()}|{user.lower()}"
    allowed, retry_after = core.rl_check_and_hit(rate_key, core.WINDOW_SEC, core.MAX_ATTEMPTS)
    if not allowed:
        core.log_attempt(
            user, True, "api_products", "ratelimited",
            route=request.path, meta={"retry_after": retry_after},
        )
        err = core.api_error("ratelimited")
        err.headers["Retry-After"] = str(retry_after)
        return err

    q = (request.args.get("q") or "").strip()
    q = q[:200]

    min_price_raw = request.args.get("min_price")
    max_price_raw = request.args.get("max_price")
    min_price = core.parse_float_or_none(min_price_raw)
    max_price = core.parse_float_or_none(max_price_raw)

    if (min_price_raw not in (None, "") and min_price is None) or (
        max_price_raw not in (None, "") and max_price is None
    ):
        core.log_attempt(
            user, True, "api_products", "invalid_param",
            route=request.path,
            meta={"min_price_raw": min_price_raw, "max_price_raw": max_price_raw},
        )
        return core.api_error("invalid_param")

    if min_price is not None and max_price is not None and max_price < min_price:
        core.log_attempt(
            user, True, "api_products", "invalid_range",
            route=request.path,
            meta={"min_price": min_price, "max_price": max_price},
        )
        return core.api_error("invalid_range")

    raw_limit = request.args.get("limit")
    raw_offset = request.args.get("offset")

    try:
        limit = core.parse_int(raw_limit, default=20, min_v=1, max_v=100)
        offset = core.parse_int(raw_offset, default=0, min_v=0, max_v=10_000)
    except ValueError as e:
        err_code = str(e)
        core.log_attempt(
            user, True, "api_products", err_code,
            route=request.path,
            meta={"limit": raw_limit, "offset": raw_offset},
        )
        return core.api_error(err_code)

    sort_by_raw = (request.args.get("sort_by") or "name").lower()
    sort_dir_raw = (request.args.get("sort_dir") or "asc").lower()

    if sort_by_raw not in ("id", "name", "price"):
        core.log_attempt(
            user, True, "api_products", "invalid_sort_by",
            route=request.path,
            meta={"sort_by": sort_by_raw},
        )
        return core.api_error("invalid_sort_by")

    if sort_dir_raw not in ("asc", "desc"):
        core.log_attempt(
            user, True, "api_products", "invalid_sort_dir",
            route=request.path,
            meta={"sort_dir": sort_dir_raw},
        )
        return core.api_error("invalid_sort_dir")

    filters = []
    params = []

    if q:
        filters.append("name LIKE ? COLLATE NOCASE")
        params.append(f"%{q}%")

    if min_price is not None:
        filters.append("price >= ?")
        params.append(min_price)

    if max_price is not None:
        filters.append("price <= ?")
        params.append(max_price)

    WHERE_SQL = (" WHERE " + " AND ".join(filters)) if filters else ""

    ORDER_SQL = {
        ("id", "asc"): " ORDER BY id ASC",
        ("id", "desc"): " ORDER BY id DESC",
        ("name", "asc"): " ORDER BY name ASC, id ASC",
        ("name", "desc"): " ORDER BY name DESC, id ASC",
        ("price", "asc"): " ORDER BY price ASC, id ASC",
        ("price", "desc"): " ORDER BY price DESC, id ASC",
    }[(sort_by_raw, sort_dir_raw)]

    COUNT_SQL = "SELECT COUNT(*) AS c FROM products" + WHERE_SQL + ";"

    PAGE_SQL = "SELECT id, name, price FROM products" + WHERE_SQL + ORDER_SQL + " LIMIT ? OFFSET ?;"
    with sqlite3.connect(core.DB_PATH) as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()

        cur.execute(COUNT_SQL, tuple(params))
        row = cur.fetchone()
        total = int(row["c"]) if row else 0

        page_params = tuple(params) + (limit, offset)
        cur.execute(PAGE_SQL, page_params)
        items = [dict(r) for r in cur.fetchall()]

    qp = {"limit": limit}
    if q:
        qp["q"] = q
    if min_price is not None:
        qp["min_price"] = min_price
    if max_price is not None:
        qp["max_price"] = max_price
    qp["sort_by"] = sort_by_raw
    qp["sort_dir"] = sort_dir_raw

    links = []
    if offset > 0:
        prev_qp = dict(qp)
        prev_qp["offset"] = max(0, offset - limit)
        prev_url = f"/api/v1/products?{urlencode(prev_qp)}"
        links.append(f'<{prev_url}>; rel="prev"')

    if offset + limit < total:
        next_qp = dict(qp)
        next_qp["offset"] = offset + limit
        next_url = f"/api/v1/products?{urlencode(next_qp)}"
        links.append(f'<{next_url}>; rel="next"')

    resp_headers = {}
    if links:
        resp_headers["Link"] = ", ".join(links)

    core.log_attempt(
        user, True, "sqli_surface", "param_safe",
        route=request.path, meta={"q": q},
    )
    core.log_attempt(
        user, True, "api_products", "list",
        route=request.path,
        meta={
            "q": q,
            "min": min_price,
            "max": max_price,
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
