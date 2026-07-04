from pathlib import Path
import os
import sqlite3

from flask import Blueprint, jsonify

health_bp = Blueprint("health", __name__)


@health_bp.get("/health")
def health():
    return jsonify(status="ok")


@health_bp.get("/ready")
def ready():
    db_path_raw = os.getenv("DB_PATH", "").strip()

    if not db_path_raw:
        return jsonify(
            status="not_ready",
            reason="DB_PATH is not configured",
        ), 503

    db_path = Path(db_path_raw)

    if not db_path.is_absolute():
        db_path = Path.cwd() / db_path

    try:
        if not db_path.exists():
            return jsonify(
                status="not_ready",
                reason="database file is missing",
            ), 503

        if not db_path.is_file():
            return jsonify(
                status="not_ready",
                reason="database path is not a file",
            ), 503

        if db_path.stat().st_size == 0:
            return jsonify(
                status="not_ready",
                reason="database file is empty",
            ), 503

        db_uri = db_path.resolve().as_uri() + "?mode=ro"

        with sqlite3.connect(db_uri, uri=True, timeout=1) as conn:
            table_count = conn.execute(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'"
            ).fetchone()[0]

            if table_count < 1:
                return jsonify(
                    status="not_ready",
                    reason="database schema is missing",
                ), 503

            conn.execute("SELECT 1").fetchone()

    except OSError:
        return jsonify(
            status="not_ready",
            reason="database path is not accessible",
        ), 503

    except sqlite3.Error:
        return jsonify(
            status="not_ready",
            reason="database is not readable",
        ), 503

    return jsonify(status="ready")