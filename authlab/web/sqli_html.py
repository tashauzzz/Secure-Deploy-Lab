import sqlite3

from flask import (
    render_template,
    request,
    redirect,
    url_for,
    session,
)

from authlab import core
from authlab.web import web_bp


@web_bp.get("/products")
def products():
    """Products listing with SQLi PoC or safe mode."""
    user = session.get("user")
    if not user:
        return redirect(url_for("web.login_get"))

    q = (request.args.get("q", "") or "").strip()[:200]
    searched = bool(q)
    results = []

    reason = "concat_raw" if core.SQLI_STATE == "poc" else "param_safe"

    if searched:
        with sqlite3.connect(core.DB_PATH) as conn:
            conn.row_factory = sqlite3.Row
            cur = conn.cursor()

            if core.SQLI_STATE == "poc":
                sql = f"SELECT id, name, price FROM products WHERE name LIKE '%{q}%';"
                cur.execute(sql)
                results = cur.fetchall()
            else:
                search = f"%{q}%"
                cur.execute(
                    "SELECT id, name, price FROM products WHERE name LIKE ?;",
                    (search,),
                )
                results = cur.fetchall()

    core.log_attempt(
        user,
        True,
        "sqli_surface",
        reason,
        route=request.path,
        meta={
            "len": len(q),
            "searched": searched,
            "count": len(results),
        },
    )

    return render_template(
        "products.html",
        q=q,
        results=results,
        searched=searched,
        state=core.SQLI_STATE,
    )