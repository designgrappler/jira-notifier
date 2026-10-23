#!/usr/bin/env python3
"""
MCP JSON-RPC + Jira REST API client.
Attempts the MCP endpoint first; falls back to the Jira REST search API.
Endpoints are derived from jira_url (and optional mcp_url) in
~/.config/jira-server-notifier/config.json.
"""

import os
import sys
import json
import logging
import urllib.request
import urllib.parse
import urllib.error
from auth import get_valid_access_token, AuthExpiredError, NetworkAuthError


def _load_endpoints() -> tuple:
    """Load Jira URLs from config and derive MCP/REST endpoints."""
    config_path = os.path.expanduser("~/.config/jira-server-notifier/config.json")
    try:
        with open(config_path, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
    jira_url = cfg.get("jira_url", "").rstrip("/")
    parsed   = urllib.parse.urlparse(jira_url)
    mcp_host = f"mcp.{parsed.netloc}" if parsed.netloc else ""
    mcp_base = urllib.parse.urlunparse((parsed.scheme, mcp_host, "", "", "", "")) if mcp_host else ""
    mcp_url  = cfg.get("mcp_url", mcp_base)
    rest_endpoints = [
        f"{jira_url}/rest/api/2/search",
        f"{jira_url}/rest/api/latest/search",
    ] if jira_url else []
    return (f"{mcp_url}/mcp" if mcp_url else ""), rest_endpoints


MCP_ENDPOINT, REST_ENDPOINTS = _load_endpoints()

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    # MCP endpoint requires both content types declared; responses may arrive as SSE
    "Accept": "application/json, text/event-stream",
    "X-Atlassian-Token": "no-check",
}


def _parse_mcp_response(raw: str) -> dict:
    """Parse a plain JSON or SSE-formatted MCP response.

    SSE lines look like:
        event: message\r\n
        data: {...json...}\r\n
        \r\n
    We scan every line for the first non-empty data: payload.
    """
    stripped = raw.strip()
    if not stripped:
        raise RuntimeError("Empty response from MCP endpoint")

    # Plain JSON (starts with { or [)
    if stripped[0] in ('{', '['):
        return json.loads(stripped)

    # SSE: scan all lines for a data: payload
    for line in stripped.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            payload = line[5:].strip()
            if payload and payload != "[DONE]":
                return json.loads(payload)

    raise RuntimeError(f"No parseable data in MCP response: {stripped[:120]!r}")


class JiraMCPClient:
    def __init__(self):
        self._rpc_id = 0

    def _rpc(self, method: str, params: dict, token: str) -> dict:
        self._rpc_id += 1
        payload = json.dumps({"jsonrpc": "2.0", "id": self._rpc_id, "method": method, "params": params}).encode()
        req = urllib.request.Request(MCP_ENDPOINT, data=payload, method="POST")
        for k, v in HEADERS.items():
            req.add_header(k, v)
        req.add_header("Content-Type", "application/json; charset=utf-8")
        req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                raw = resp.read().decode()
                body = _parse_mcp_response(raw)
                if "error" in body:
                    code = body["error"].get("code")
                    msg  = body["error"].get("message", "")
                    if code in (-32001, 401, 403):
                        raise AuthExpiredError(f"MCP auth error: {msg}")
                    raise RuntimeError(f"MCP error {code}: {msg}")
                return body.get("result", {})
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise AuthExpiredError(f"HTTP {e.code} — session expired")
            raise RuntimeError(f"MCP HTTP {e.code}")
        except urllib.error.URLError as e:
            raise NetworkAuthError(f"MCP unreachable: {e.reason}")
        except (AuthExpiredError, NetworkAuthError):
            raise
        except Exception as e:
            raise RuntimeError(f"MCP call failed: {e}")

    def _rest_search(self, project_key: str, max_results: int, token: str) -> list:
        jql = f"project = {project_key} ORDER BY updated DESC"
        qs = urllib.parse.urlencode({
            "jql": jql,
            "maxResults": max_results,
            "fields": "summary,status,assignee,updated,comment",
        })
        last_err = None
        for endpoint in REST_ENDPOINTS:
            req = urllib.request.Request(f"{endpoint}?{qs}", method="GET")
            for k, v in HEADERS.items():
                req.add_header(k, v)
            req.add_header("Authorization", f"Bearer {token}")
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    data = json.loads(resp.read().decode())
                    issues = data.get("issues", [])
                    logging.info("REST: fetched %d issues from %s", len(issues), endpoint)
                    return issues
            except urllib.error.HTTPError as e:
                if e.code in (401, 403):
                    raise AuthExpiredError(f"REST auth error: HTTP {e.code}")
                last_err = e
                logging.warning("REST %s → HTTP %d", endpoint, e.code)
            except urllib.error.URLError as e:
                raise NetworkAuthError(f"Network unreachable: {e.reason}")
            except Exception as e:
                last_err = e
                logging.warning("REST %s error: %s", endpoint, e)
        raise NetworkAuthError(f"All REST endpoints failed: {last_err}")

    def get_issue_dates(self, issue_key: str) -> dict:
        """Fetch status transition history for one issue. Returns {} on any error."""
        token = get_valid_access_token()
        try:
            result = self._rpc("tools/call", {
                "name": "jira_get_issue_dates",
                "arguments": {"issue_key": issue_key},
            }, token)
            if result.get("isError"):
                return {}
            for item in result.get("content", []):
                if item.get("type") == "text":
                    try:
                        return json.loads(item["text"])
                    except Exception:
                        pass
            return {}
        except Exception:
            return {}

    def fetch_project_issues(self, project_key: str, max_results: int = 50) -> list:
        token = get_valid_access_token()
        try:
            result = self._rpc("tools/call", {
                "name": "jira_search",
                "arguments": {
                    "jql": f"project = {project_key} ORDER BY updated DESC",
                    "fields": "summary,status,assignee,reporter,updated,comment,resolution",
                    "limit": min(max_results, 50),
                },
            }, token)
            if result.get("isError"):
                err_text = " ".join(
                    i.get("text", "") for i in result.get("content", []) if i.get("type") == "text"
                )
                raise RuntimeError(f"MCP tool error: {err_text}")
            for item in result.get("content", []):
                if item.get("type") == "text":
                    try:
                        parsed = json.loads(item["text"])
                        if isinstance(parsed, dict) and "issues" in parsed:
                            return parsed["issues"]
                        if isinstance(parsed, list):
                            return parsed
                    except Exception:
                        pass
            if "issues" in result:
                return result["issues"]
            logging.warning("MCP returned no parseable issues: %r", result)
            return []
        except AuthExpiredError:
            raise
        except Exception as e:
            logging.info("MCP unavailable (%s), falling back to REST.", e)
        return self._rest_search(project_key, max_results, token)


if __name__ == "__main__":
    proj = sys.argv[1] if len(sys.argv) > 1 else "UAT10"
    client = JiraMCPClient()
    try:
        issues = client.fetch_project_issues(proj, max_results=5)
        print(f"Fetched {len(issues)} issues for {proj}")
    except AuthExpiredError as e:
        print(f"Auth expired: {e}"); sys.exit(2)
    except NetworkAuthError as e:
        print(f"Network error: {e}"); sys.exit(3)
    except Exception as e:
        print(f"Error: {e}"); sys.exit(1)
