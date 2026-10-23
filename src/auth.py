#!/usr/bin/env python3
"""
OAuth 2.1 PKCE authentication and token management for self-hosted Jira Server.
Tokens are stored encrypted in the macOS Keychain.
"""

import sys
import json
import time
import base64
import hashlib
import secrets
import subprocess
import urllib.request
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler

KEYCHAIN_SERVICE = "io.github.jiraservernotifier"
KEYCHAIN_ACCOUNT = "oauth_token"


def _read_config() -> dict:
    config_path = os.path.expanduser("~/.config/jira-server-notifier/config.json")
    try:
        with open(config_path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _mcp_base_from_jira_url(jira_url: str) -> str:
    """Derive MCP server base URL by prepending 'mcp.' to the Jira host."""
    parsed = urllib.parse.urlparse(jira_url)
    if not parsed.netloc:
        return ""
    return urllib.parse.urlunparse((parsed.scheme, f"mcp.{parsed.netloc}", "", "", "", ""))


_cfg       = _read_config()
_jira_url  = _cfg.get("jira_url", "").rstrip("/")
_mcp_base  = _cfg.get("mcp_url", _mcp_base_from_jira_url(_jira_url))

DISCOVERY_URL  = f"{_mcp_base}/.well-known/oauth-authorization-server" if _mcp_base else ""
TOKEN_ENDPOINT = f"{_mcp_base}/token" if _mcp_base else ""
AUTH_ENDPOINT  = f"{_mcp_base}/authorize" if _mcp_base else ""
CLIENT_ID      = "jira-server-notifier"
REDIRECT_URI   = "http://127.0.0.1:8765/callback"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Accept": "application/json, text/plain, */*",
}


class AuthExpiredError(Exception):
    pass


class NetworkAuthError(Exception):
    pass


def _discover_endpoints():
    """Fetch OAuth discovery doc and update endpoints if available."""
    global AUTH_ENDPOINT, TOKEN_ENDPOINT
    if not DISCOVERY_URL:
        return
    try:
        req = urllib.request.Request(DISCOVERY_URL)
        for k, v in HEADERS.items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=10) as resp:
            doc = json.loads(resp.read().decode())
            AUTH_ENDPOINT  = doc.get("authorization_endpoint", AUTH_ENDPOINT)
            TOKEN_ENDPOINT = doc.get("token_endpoint", TOKEN_ENDPOINT)
    except Exception:
        pass  # fall back to hardcoded values


def _pkce_pair():
    verifier = secrets.token_urlsafe(64)[:128]
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).decode().rstrip("=")
    return verifier, challenge


class _CallbackHandler(BaseHTTPRequestHandler):
    auth_code = None
    error = None

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/callback":
            params = urllib.parse.parse_qs(parsed.query)
            if "code" in params:
                _CallbackHandler.auth_code = params["code"][0]
                self.send_response(200)
                self.send_header("Content-type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"""
                <html><body style="font-family:-apple-system,sans-serif;text-align:center;padding:50px;background:#f5f5f7">
                <div style="background:white;border-radius:12px;padding:40px;display:inline-block;box-shadow:0 4px 12px rgba(0,0,0,.1)">
                <h2 style="color:#34c759">&#10003; Authorization Successful!</h2>
                <p style="color:#666">You may now close this tab and return to Jira Server Notifier.</p>
                </div></body></html>""")
            else:
                _CallbackHandler.error = params.get("error", ["unknown"])[0]
                self.send_response(400)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


def _save_keychain(token_data: dict) -> bool:
    payload = json.dumps(token_data)
    subprocess.run(
        ["security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT],
        capture_output=True
    )
    res = subprocess.run(
        ["security", "add-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w", payload, "-U", "-A"],
        capture_output=True, text=True
    )
    return res.returncode == 0


def _load_keychain():
    res = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
        capture_output=True, text=True
    )
    if res.returncode != 0 or not res.stdout.strip():
        return None
    try:
        return json.loads(res.stdout.strip())
    except Exception:
        return None


def _exchange_code(code: str, verifier: str) -> dict:
    data = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "client_id": CLIENT_ID,
        "code": code,
        "redirect_uri": REDIRECT_URI,
        "code_verifier": verifier,
    }).encode()
    req = urllib.request.Request(TOKEN_ENDPOINT, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    for k, v in HEADERS.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode())
            result["created_at"] = time.time()
            return result
    except urllib.error.HTTPError as e:
        raise AuthExpiredError(f"Token exchange failed (HTTP {e.code})")
    except Exception as e:
        raise NetworkAuthError(f"Cannot reach token endpoint: {e}")


def _refresh_token(refresh_token: str) -> dict:
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "client_id": CLIENT_ID,
        "refresh_token": refresh_token,
    }).encode()
    req = urllib.request.Request(TOKEN_ENDPOINT, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    for k, v in HEADERS.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode())
            result["created_at"] = time.time()
            if "refresh_token" not in result:
                result["refresh_token"] = refresh_token
            return result
    except urllib.error.HTTPError as e:
        if e.code in (400, 401, 403):
            raise AuthExpiredError("Refresh token expired or revoked")
        raise NetworkAuthError(f"HTTP {e.code} during refresh")
    except Exception as e:
        raise NetworkAuthError(f"Network error during token refresh: {e}")


def get_valid_access_token() -> str:
    tokens = _load_keychain()
    if not tokens:
        raise AuthExpiredError("No credentials in Keychain. Please authenticate via Reconnect.")

    access_token  = tokens.get("access_token")
    expires_in    = tokens.get("expires_in", 3600)
    created_at    = tokens.get("created_at", 0)
    refresh_tok   = tokens.get("refresh_token")

    if time.time() < (created_at + expires_in - 60):
        return access_token

    if refresh_tok:
        try:
            new = _refresh_token(refresh_tok)
            _save_keychain(new)
            return new["access_token"]
        except AuthExpiredError:
            raise AuthExpiredError("Session expired. Please use Reconnect to re-authenticate.")
        except NetworkAuthError:
            if access_token:
                return access_token
            raise

    return access_token


def interactive_login() -> bool:
    if not _jira_url:
        print("✗ No Jira Server URL configured.")
        print("  Set jira_url in ~/.config/jira-server-notifier/config.json or via Preferences.")
        return False
    _discover_endpoints()
    if not AUTH_ENDPOINT or not TOKEN_ENDPOINT:
        print(f"✗ Could not determine OAuth endpoints for {_jira_url}.")
        print("  Optionally set mcp_url in config.json to override.")
        return False
    verifier, challenge = _pkce_pair()
    state = secrets.token_hex(16)

    params = urllib.parse.urlencode({
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "scope": "jira.read",
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    })
    auth_url = f"{AUTH_ENDPOINT}?{params}"

    host = urllib.parse.urlparse(_jira_url).netloc or _jira_url
    print("\n=======================================================")
    print(" Jira Server Notifier — OAuth 2.1 PKCE Authentication")
    print("=======================================================")
    print(f"Connecting to: {host}")
    print(f"Opening browser for login...")
    print(f"URL: {auth_url}\n")

    _CallbackHandler.auth_code = None
    _CallbackHandler.error = None
    server = HTTPServer(("127.0.0.1", 8765), _CallbackHandler)
    server.timeout = 180

    subprocess.run(["/usr/bin/open", auth_url])
    print("Waiting for authorization (3-minute window)...")

    while _CallbackHandler.auth_code is None and _CallbackHandler.error is None:
        server.handle_request()
    server.server_close()

    if _CallbackHandler.auth_code:
        try:
            tokens = _exchange_code(_CallbackHandler.auth_code, verifier)
            if _save_keychain(tokens):
                print("✓ Authenticated. Tokens stored in macOS Keychain.\n")
                return True
            print("✗ Failed to save tokens to Keychain.")
            return False
        except Exception as e:
            print(f"✗ Token exchange failed: {e}")
            return False
    else:
        print(f"✗ Authorization failed: {_CallbackHandler.error}")
        return False


if __name__ == "__main__":
    if "--login" in sys.argv:
        sys.exit(0 if interactive_login() else 1)
    elif "--status" in sys.argv:
        try:
            get_valid_access_token()
            print("Status: Connected")
            sys.exit(0)
        except AuthExpiredError:
            print("Status: Auth Expired")
            sys.exit(2)
        except NetworkAuthError:
            print("Status: Offline")
            sys.exit(3)
    elif "--logout" in sys.argv:
        subprocess.run(["security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT])
        print("Logged out.")
    else:
        interactive_login()
