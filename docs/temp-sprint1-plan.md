# Sprint S1 Plan

**Sprint ID:** S1
**Status:** OPEN
**Authored-by:** Orchestrator
**Date:** 2026-10-22
**Release target:** TBD

---

## Sprint Objective

Ship multi-project tab navigation and a manual update check to the macOS menubar app.

---

## Tracks

| Track ID | Description | Owner | Status |
|---|---|---|---|
| T1 | Multi-project support — tabbed UI with truncation and horizontal navigation | technical | STUB |
| T2 | Manual update check — "Check for Updates" menu item via GitHub releases API | technical | STUB |

---

## Constraints

- No Sparkle or other auto-update frameworks — manual check only (T2)
- Tabs must handle truncation gracefully; assume 1–3 projects as the common case (T1)
- No changes to Python daemon polling logic beyond accepting multiple project keys (T1)
- No App Store distribution changes

---

## Sequencing

T1 and T2 are independent — can execute in parallel.

---

## Sprint Close Conditions

- Multi-project tab UI renders correctly for 1, 2, and 3 project keys
- Tabs truncate cleanly when project keys are long; horizontal navigation works
- "Check for Updates" menu item queries GitHub releases API and opens browser when a newer version is available; shows "up to date" when current
- Build (`./build-dmg.sh`) passes clean

<!-- ORCHESTRATOR SECTION END — do not edit above this line -->

---

## T1 — Multi-project support

**Owner:** technical
**Status:** STUB

<!-- technical: fill this section before executing -->

**Description:**

**Scope:**

**Key files:**

**Verification criteria:**

---

## T2 — Manual update check

**Owner:** technical
**Status:** STUB

<!-- technical: fill this section before executing -->

**Description:**

**Scope:**

**Key files:**

**Verification criteria:**
