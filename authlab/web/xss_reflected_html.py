from flask import (
    render_template,
    request,
    redirect,
    url_for,
    session,
)

from authlab import core
from authlab.web import web_bp

@web_bp.get("/search")
def search():
    """Reflected XSS surface (safe or PoC mode)."""
    user = session.get("user")
    if not user:
        return redirect(url_for("web.login_get"))

    q = request.args.get("q", "")
    q = q[:200]
    reason = "reflected_poc" if core.XSS_R_STATE == "poc" else "reflected_safe"
    core.log_attempt(
        user,
        True,
        "xss_surface",
        reason,
        route=request.path,
        meta={"len": len(q)},
    )
    return render_template("search.html", q=q, state=core.XSS_R_STATE)