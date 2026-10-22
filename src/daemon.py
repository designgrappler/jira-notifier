#!/usr/bin/env python3
"""
Polling worker for Jira Notifier.
Run with --check-once for a single poll (invoked by the Swift menu bar app).
Run without arguments for a continuous background loop.
Exit codes: 0=ok, 2=auth expired, 3=offline, 1=other error.
"""

import os
import sys

# Swift runs this with -I (isolated mode), which strips the script dir from sys.path.
# Re-add it so local sibling imports (mcp_client, auth, etc.) resolve correctly.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import json
import time
import logging
from datetime import datetime
from mcp_client import JiraMCPClient
from change_tracker import detect_changes, save_current_state, load_previous_state
from notifier import notify_changes, notify_auth_disconnected, notify_offline
from auth import AuthExpiredError, NetworkAuthError

CONFIG_DIR    = os.path.expanduser("~/.config/jira-notifier")
CONFIG_FILE   = os.path.join(CONFIG_DIR, "config.json")
STATUS_FILE   = os.path.join(CONFIG_DIR, "status.json")
CHANGES_FILE  = os.path.join(CONFIG_DIR, "changes.json")
LOG_FILE      = os.path.join(CONFIG_DIR, "notifier.log")

os.makedirs(CONFIG_DIR, exist_ok=True)

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)


def _append_changes(new_changes: list):
    try:
        with open(CHANGES_FILE, encoding="utf-8") as f:
            existing = json.load(f)
    except Exception:
        existing = []
    existing.extend(new_changes)
    with open(CHANGES_FILE, "w", encoding="utf-8") as f:
        json.dump(existing, f, indent=2)


def _load_config() -> dict:
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"project_key": "FUN", "interval_minutes": 5}


def _write_status(status: str, project_key: str, changes: int = 0, error: str = None):
    data = {
        "status":           status,
        "project_key":      project_key,
        "last_checked":     datetime.now().isoformat(),
        "changes_detected": changes,
        "error":            error,
    }
    try:
        with open(STATUS_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        logging.error("Failed to write status: %s", e)


def perform_check() -> int:
    config      = _load_config()
    project_key = config.get("project_key", "FUN")
    logging.info("Checking project %s...", project_key)

    client = JiraMCPClient()
    try:
        issues      = client.fetch_project_issues(project_key, max_results=50)
        prev_state  = load_previous_state()
        is_initial  = len(prev_state) == 0

        changes, new_state = detect_changes(issues, is_initial_run=is_initial, client=client)
        save_current_state(new_state)

        if changes:
            logging.info("Detected %d changes in %s.", len(changes), project_key)
            _append_changes(changes)
            notify_changes(changes, project_key)
        else:
            logging.info("No changes in %s.", project_key)

        _write_status("connected", project_key, changes=len(changes))
        return 0

    except AuthExpiredError as e:
        logging.error("Auth expired: %s", e)
        _write_status("auth_expired", project_key, error=str(e))
        notify_auth_disconnected()
        return 2

    except NetworkAuthError as e:
        logging.error("Network error: %s", e)
        _write_status("offline", project_key, error=str(e))
        notify_offline(str(e))
        return 3

    except Exception as e:
        logging.error("Unexpected error: %s", e, exc_info=True)
        _write_status("error", project_key, error=str(e))
        return 1


def main():
    if "--check-once" in sys.argv:
        sys.exit(perform_check())

    logging.info("Starting background polling loop...")
    while True:
        try:
            perform_check()
        except Exception as e:
            logging.error("Poll loop error: %s", e)
        interval = max(1, _load_config().get("interval_minutes", 5))
        time.sleep(interval * 60)


if __name__ == "__main__":
    main()
