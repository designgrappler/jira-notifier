#!/usr/bin/env python3
"""macOS notification dispatch for Jira Server Notifier.

Notifications are handled by the Swift app via UNUserNotificationCenter.
These functions are intentionally no-ops to avoid duplicate system alerts.
"""


def _notify(title: str, message: str):
    pass


def notify_changes(changes: list, project_key: str = ""):
    pass


def notify_auth_disconnected():
    pass


def notify_offline(error: str = ""):
    pass
