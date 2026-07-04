#!/usr/bin/env python3
"""
Initialize or verify the AuthLab demo database.
Seed both the interactive demo principal (`admin`) and a foreign owner (`alice`).
`alice` exists to exercise non-owned resource checks and is not a bootstrapped runtime account.

Usage:
  python scripts/db/db_init.py init
  python scripts/db/db_init.py verify
"""

import os
import sys
import sqlite3
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
SCHEMA_VERSION = 1

PRODUCTS = [
    ("Laptop Go 12", 799.0), ("Laptop Air 13", 999.0), ("Laptop Lite 13", 849.0),
    ("Laptop Pro 14", 1299.0), ("Laptop Work 14", 1099.0), ("Laptop Flex 14", 1049.0),
    ("Laptop Gamer 15", 1499.0), ("Laptop Studio 15", 1599.0),
    ("Laptop Ultra 16", 1799.0), ("Laptop Flex 16", 1399.0),
    ("Laptop Neo 13", 929.0), ("Laptop Edge 14", 1149.0),
    ("Phone Max", 899.0), ("Phone Mini", 499.0),
    ("Router AX1800", 119.0), ("Router AX3000", 139.0),
    ('Monitor 27"', 249.0), ("Keyboard Mech", 89.0),
]

NOTES = [
    ("Admin note #1", "Seeded note 1 for admin", "admin"),
    ("Admin note #2", "Seeded note 2 for admin", "admin"),
    ("Admin note #3", "Seeded note 3 for admin", "admin"),
    ("Alice note #1", "Seeded note 1 for alice", "alice"),
    ("Alice note #2", "Seeded note 2 for alice", "alice"),
    ("Alice note #3", "Seeded note 3 for alice", "alice"),
]


def die(msg):
    """Stop the script with a fatal error message."""
    raise SystemExit(msg)


def resolve_db_path():
    """Resolve DB_PATH from the environment into an absolute database path."""
    env_db = os.getenv("DB_PATH")
    if not env_db:
        die("DB_PATH is required (set it in .env / .env.ci)")

    db_path = Path(env_db)
    if not db_path.is_absolute():
        db_path = (REPO_ROOT / db_path).resolve()

    return db_path


def get_mode():
    """Read and validate the command mode: init or verify."""
    if len(sys.argv) != 2:
        die("Usage: python scripts/db/db_init.py [init|verify]")

    mode = sys.argv[1].strip().lower()
    if mode not in ("init", "verify"):
        die("Unsupported mode. Use: init or verify")

    return mode


def init_db(db_path):
    """Recreate the SQLite database and seed deterministic demo data."""
    db_path.parent.mkdir(parents=True, exist_ok=True)

    if db_path.exists():
        db_path.unlink()

    conn = sqlite3.connect(db_path.as_posix())
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    cur.execute("""
        CREATE TABLE products (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            price REAL NOT NULL
        );
    """)

    cur.execute("""
        CREATE TABLE notes (
            id    INTEGER PRIMARY KEY,
            title TEXT    NOT NULL,
            body  TEXT    NOT NULL,
            owner TEXT    NOT NULL
        );
    """)

    cur.execute("""
        CREATE TABLE guestbook_messages (
            id      INTEGER PRIMARY KEY,
            ts      TEXT    NOT NULL,
            user    TEXT    NOT NULL,
            message TEXT    NOT NULL
        );
    """)

    cur.executemany("INSERT INTO products (name, price) VALUES (?,?)", PRODUCTS)
    cur.executemany("INSERT INTO notes (title, body, owner) VALUES (?,?,?)", NOTES)

    cur.execute("PRAGMA user_version = %d;" % SCHEMA_VERSION)
    conn.commit()

    cur.execute("SELECT COUNT(*) AS c FROM products;")
    products_count = cur.fetchone()["c"]

    cur.execute("SELECT COUNT(*) AS c FROM notes;")
    notes_count = cur.fetchone()["c"]

    cur.execute("SELECT COUNT(*) AS c FROM notes WHERE owner=?;", ("admin",))
    admin_count = cur.fetchone()["c"]

    cur.execute("SELECT COUNT(*) AS c FROM notes WHERE owner=?;", ("alice",))
    alice_count = cur.fetchone()["c"]

    conn.close()

    print(f"{db_path} recreated")
    print(f"schema version: {SCHEMA_VERSION}")
    print(f"products: {products_count} rows")
    print(f"notes: {notes_count} rows (admin={admin_count}, alice={alice_count})")
    


def verify_db(db_path):
    """Verify database integrity, schema version, tables, and required seed data."""
    if not db_path.exists():
        die(f"Database file not found: {db_path}")

    if db_path.stat().st_size <= 0:
        die(f"Database file is empty: {db_path}")

    conn = sqlite3.connect(db_path.as_posix())
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    cur.execute("PRAGMA integrity_check;")
    integrity = cur.fetchone()[0]
    if integrity != "ok":
        conn.close()
        die(f"SQLite integrity_check failed: {integrity}")

    cur.execute("PRAGMA user_version;")
    user_version = cur.fetchone()[0]
    if user_version != SCHEMA_VERSION:
        conn.close()
        die(
            f"Unexpected schema version: {user_version} "
            f"(expected {SCHEMA_VERSION})"
        )

    cur.execute("SELECT name FROM sqlite_master WHERE type='table';")
    table_names = {row["name"] for row in cur.fetchall()}
    required_tables = {"products", "notes", "guestbook_messages"}
    missing_tables = sorted(required_tables - table_names)
    if missing_tables:
        conn.close()
        die("Missing required tables: " + ", ".join(missing_tables))

    cur.execute("SELECT COUNT(*) AS c FROM products;")
    products_count = cur.fetchone()["c"]
    if products_count <= 0:
        conn.close()
        die("products table is empty")

    cur.execute("SELECT COUNT(*) AS c FROM notes;")
    notes_count = cur.fetchone()["c"]
    if notes_count <= 0:
        conn.close()
        die("notes table is empty")
    
    cur.execute("SELECT COUNT(*) AS c FROM notes WHERE owner=?;", ("admin",))
    admin_count = cur.fetchone()["c"]
    if admin_count <= 0:
        conn.close()
        die("admin notes are missing")

    cur.execute("SELECT COUNT(*) AS c FROM notes WHERE owner=?;", ("alice",))
    alice_count = cur.fetchone()["c"]
    if alice_count <= 0:
        conn.close()
        die("alice notes are missing")
    conn.close()

    print(f"{db_path} verified")
    print(f"schema version: {user_version}")
    print(f"products: {products_count} rows")
    print(f"notes: {notes_count} rows (admin={admin_count}, alice={alice_count})")


def main():
    """Run the requested database command."""
    mode = get_mode()
    db_path = resolve_db_path()

    if mode == "init":
        init_db(db_path)
    else:
        verify_db(db_path)


if __name__ == "__main__":
    main()