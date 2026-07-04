from flask import Blueprint

web_bp = Blueprint("web", __name__)

# Import modules that attach routes to web_bp
from . import auth_html, xss_reflected_html, xss_stored_html, sqli_html, idor_html  # noqa: E402,F401
