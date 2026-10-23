# Jira Server Notifier

A lightweight macOS menu bar app that watches your self-hosted Jira Server and surfaces issue updates as native notifications — without keeping a browser tab open.

Built for **macOS** and **self-hosted Jira Server** with OAuth 2.1 support.

---

## What it does

Jira Server Notifier runs silently in your menu bar. Every few minutes it polls your Jira project for new activity — status changes, comments, new issues — and delivers them as macOS notifications and a browsable update panel. When something changes, a red dot appears on the icon. Click it to see exactly what moved.

```
┌──────────────────────────────────────────────────────────────┐
│  Apple  File  Edit  View  Window                [J]•  11:42  │
└──────────────────────────────────────────────────────────────┘
                                                   ↑
                                        Jira Server Notifier icon
                                        (• = unread updates)
```

Clicking the icon opens the updates panel:

```
┌──────────────────────────────────────────────┐
│  FUN – 3 updates since 2 hours ago        ✕  │
├──────────────────────────────────────────────┤
│  Jane updated FUN-42 – Fix login page        │
│  2 hours ago                                 │
├──────────────────────────────────────────────┤
│  Bob closed FUN-38 – Add dark mode           │
│  3 hours ago                                 │
├──────────────────────────────────────────────┤
│  New issue FUN-51 – API timeout on retry     │
│  5 hours ago                                 │
├──────────────────────────────────────────────┤
│  ⚙   [ Open All in Browser ]   [ Clear All ] │
└──────────────────────────────────────────────┘
```

Click any row to open that issue in your browser. Click **Clear All** once you've reviewed them.

---

## Requirements

| Requirement | Notes |
|---|---|
| macOS | 11 (Big Sur) or later |
| Python 3 | Bundled in macOS — no separate install needed |
| Jira Server | Self-hosted, with OAuth 2.1 / MCP endpoint enabled |
| Network access | Must be able to reach your Jira server |

---

## Installation

### Step 1 — Download the DMG

Download **Jira Server Notifier-1.0.dmg** from the [Releases](../../releases) page.

```
GitHub Releases page
┌──────────────────────────────────────────────────────┐
│  Releases                                            │
│  ─────────────────────────────────────────────────── │
│  v1.0  •  Latest                                     │
│    📦  Jira Server Notifier-1.0.dmg         ← download this │
└──────────────────────────────────────────────────────┘
```

---

### Step 2 — Install the app

Open the downloaded DMG. Drag **Jira Server Notifier** into your **Applications** folder.

```
┌──────────────────────────────────────────────────┐
│               Jira Server Notifier 1.0                  │
│                                                  │
│    ┌─────────────┐          ┌──────────────┐     │
│    │  Jira       │          │              │     │
│    │  Notifier   │  ──────▶ │ Applications │     │
│    │  .app       │   drag   │   folder     │     │
│    └─────────────┘          └──────────────┘     │
└──────────────────────────────────────────────────┘
```

---

### Step 3 — Launch the app

Open **Jira Server Notifier** from your Applications folder. The Jira icon appears in your menu bar.

On first launch, a dialog prompts you to open Preferences:

```
╔═══════════════════════════════════════════╗
║         Set Up Jira Server Notifier              ║
║                                           ║
║   Enter your Jira Server URL in           ║
║   Preferences to get started.             ║
║                                           ║
║         [ Later ]  [ Open Preferences ]   ║
╚═══════════════════════════════════════════╝
```

Click **Open Preferences**.

---

### Step 4 — Enter your server details

Enter your Jira Server URL, project key, and polling interval, then click **Save**.

```
┌──────────────────────────────────────────────┐
│      Jira Server Notifier — Preferences             │
├──────────────────────────────────────────────┤
│                                              │
│   Jira Server URL:  [ https://jira.your... ] │
│   Jira Project Key: [ FUN               ]    │
│   Check Interval:   [ 5       ] minutes      │
│                                              │
│                [ Cancel ]   [ Save ]         │
└──────────────────────────────────────────────┘
```

| Field | What to enter |
|---|---|
| **Jira Server URL** | Your Jira base URL, e.g. `https://jira.yourcompany.com` |
| **Jira Project Key** | The all-caps key for your project, e.g. `FUN`, `CORE`, `PLATFORM` |
| **Check Interval** | How often to poll, in minutes. Minimum: 1. Default: 5. |

After saving, a **Connect** dialog appears automatically.

---

### Step 5 — Authorize in your browser

Click **Connect**. Your default browser opens to your Jira server's login page. Sign in with your credentials.

```
Browser                         Jira Server Notifier
──────────────────────          ─────────────────────────────
Jira Server Login          →    Waiting for authorization...
                                (3-minute window)
  [username field]
  [password field]
  [ Sign In ]
        │
        ▼
  Authorization Successful!
  You may close this tab and
  return to Jira Server Notifier.   →   ✓ Status: Connected 🟢
```

Your token is stored securely in the **macOS Keychain** — you won't need to log in again until your session expires.

---

## Using Jira Server Notifier

| Action | How |
|---|---|
| See updates | Left-click the menu bar icon |
| Open an issue | Click any row in the updates panel |
| Open all issues | Click **Open All in Browser** in the panel footer |
| Dismiss the panel | Click outside it, or click the ✕ button |
| Clear updates | Click **Clear All** |
| Change server / project / interval | Right-click icon → **Preferences…** |
| Reconnect after expiry | Right-click icon → **Reconnect / Re-authenticate…** |
| View logs | Right-click icon → **View Logs…** |

### Icon states

| Icon | Meaning |
|---|---|
| `[J]` (outline) | Connected, no new updates |
| `[J]•` (red dot) | Connected, unread updates |
| `[J]•` (orange dot) | Session expired — reconnect needed |
| `[J]•` (grey dot) | Offline — check network / VPN |

---

## License

MIT — see [LICENSE](LICENSE).
