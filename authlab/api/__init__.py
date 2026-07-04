from flask import Blueprint

api_bp = Blueprint("api", __name__)

# Import modules that attach routes to api_bp
from . import auth_api, guestbook_api, products_api, notes_api # noqa: E402,F401
