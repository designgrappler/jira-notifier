#!/usr/bin/env python3
"""
Issue state diffing for Jira projects.
Compares current issue snapshots against the previous run's state to surface changes.
"""

import os
import json
from typing import Tuple

STATE_FILE = os.path.expanduser("~/.config/jira-notifier/state.json")


def load_previous_state() -> dict:
    if not os.path.exists(STATE_FILE):
        return {}
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_current_state(state: dict):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)


def _display_name(obj) -> str:
    if isinstance(obj, dict):
        return (obj.get("displayName") or obj.get("display_name")
                or obj.get("name") or "Unknown")
    return str(obj) if obj else "Unknown"


def _normalize_ts(ts: str) -> str:
    """Convert MCP flat timestamps ('2026-10-21 21:07:04 UTC') to ISO 8601."""
    if not ts:
        return ts
    return ts.replace(" UTC", "Z").replace(" ", "T", 1) if " UTC" in ts else ts


def _format_date(iso_str: str) -> str:
    """Convert ISO/UTC timestamp to M/D/YYYY."""
    if not iso_str:
        return ""
    try:
        # Handles "2026-10-22T04:57:33.000+0000" and "2026-10-22 04:57:33 UTC"
        s = iso_str.replace(" UTC", "").replace("T", " ").split(".")[0].split("+")[0].strip()
        parts = s.split(" ")[0].split("-")
        return f"{int(parts[1])}/{int(parts[2])}/{parts[0]}"
    except Exception:
        return iso_str[:10]


def _parse(raw: dict) -> dict:
    fields = raw.get("fields", {})

    summary = fields.get("summary") or raw.get("summary", "")

    status_obj  = fields.get("status") or raw.get("status", {})
    status_name = status_obj.get("name") if isinstance(status_obj, dict) else str(status_obj or "Unknown")

    assignee_name = _display_name(fields.get("assignee") or raw.get("assignee"))

    reporter_name = _display_name(fields.get("reporter") or raw.get("reporter"))

    # REST: "comment" dict; MCP: "comments" list
    comment_list = []
    comment_data = fields.get("comment") or raw.get("comment") or raw.get("comments", [])
    if isinstance(comment_data, dict):
        comment_list = comment_data.get("comments", [])
        # Use REST's authoritative total count (never capped by pagination)
        comment_count = comment_data.get("total", len(comment_list))
    elif isinstance(comment_data, list):
        comment_list = comment_data
        comment_count = len(comment_list)
    else:
        comment_count = 0

    last_comment_author = ""
    last_comment_date   = ""
    if comment_list:
        last = comment_list[-1]
        last_comment_author = _display_name(last.get("author"))
        last_comment_date   = last.get("created", "")

    updated = fields.get("updated") or raw.get("updated", "")

    resolution_obj = fields.get("resolution") or raw.get("resolution")
    resolution_name = ""
    if isinstance(resolution_obj, dict):
        resolution_name = resolution_obj.get("name", "") or ""
    elif isinstance(resolution_obj, str):
        resolution_name = resolution_obj

    return {
        "key":                 raw.get("key", ""),
        "summary":             summary,
        "status":              status_name or "Unknown",
        "assignee":            assignee_name,
        "reporter":            reporter_name,
        "resolution":          resolution_name,
        "comment_count":       comment_count,
        "last_comment_author": last_comment_author,
        "last_comment_date":   last_comment_date,
        "updated":             updated,
    }


def detect_changes(raw_issues: list, is_initial_run: bool = False, client=None) -> Tuple[list, dict]:
    prev    = load_previous_state()
    state   = {}
    changes = []

    for raw in raw_issues:
        item = _parse(raw)
        key  = item["key"]
        if not key:
            continue
        state[key] = item

        if is_initial_run or not prev:
            continue

        if key not in prev:
            ts = _normalize_ts(item["updated"])
            changes.append({
                "type":      "new",
                "key":       key,
                "summary":   item["summary"],
                "actor":     item["reporter"],
                "verb":      "created",
                "timestamp": ts,
                "date":      _format_date(ts),
                "details":   f"Assignee: {item['assignee']} · Status: {item['status']}",
            })
        else:
            old = prev[key]
            if old.get("status") != item["status"]:
                res = item.get("resolution", "")
                res_suffix = (f" with a resolution of '{res}'"
                              if res and res.lower() not in ("unresolved", "") else "")
                actor = ""
                if client is not None:
                    try:
                        dates = client.get_issue_dates(key)
                        sc = dates.get("status_changes", [])
                        if sc:
                            last = sc[-1]
                            if last.get("status") == item["status"]:
                                actor = last.get("transitioned_by", "")
                    except Exception:
                        pass
                ts = _normalize_ts(item["updated"])
                changes.append({
                    "type":      "status_change",
                    "key":       key,
                    "summary":   item["summary"],
                    "actor":     actor,
                    "verb":      f"changed the status to {item['status']}{res_suffix} on",
                    "timestamp": ts,
                    "date":      _format_date(ts),
                    "details":   f"{old.get('status', '?')} → {item['status']}",
                })
            elif old.get("assignee") != item["assignee"]:
                ts = _normalize_ts(item["updated"])
                changes.append({
                    "type":      "assignee_change",
                    "key":       key,
                    "summary":   item["summary"],
                    "actor":     item["assignee"],
                    "verb":      "changed the assignee on",
                    "timestamp": ts,
                    "date":      _format_date(ts),
                    "details":   f"{old.get('assignee', '?')} → {item['assignee']}",
                })
            elif (item["comment_count"] > old.get("comment_count", 0) or
                  (old.get("last_comment_date") and
                   item["last_comment_date"] != old["last_comment_date"])):
                n = item["comment_count"] - old.get("comment_count", 0)
                if n < 1:
                    n = 1
                actor = item["last_comment_author"] or item["assignee"]
                ts = _normalize_ts(item["last_comment_date"] or item["updated"])
                changes.append({
                    "type":      "new_comment",
                    "key":       key,
                    "summary":   item["summary"],
                    "actor":     actor,
                    "verb":      "commented on",
                    "timestamp": ts,
                    "date":      _format_date(ts),
                    "details":   f"{n} new comment{'s' if n != 1 else ''}",
                })

    return changes, state
