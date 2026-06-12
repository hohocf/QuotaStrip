#!/usr/bin/env python3
"""QuotaStrip data layer: report Claude Code / Codex usage quota.

Usage:
    python3 quota.py json     # full JSON for QuotaStrip.app (with reset timestamps)
    python3 quota.py json --force   # bypass cache and 429 cooldown
    python3 quota.py claude   # one-line text (debug)
    python3 quota.py codex    # one-line text (debug)

JSON shape:
    {"claude": {"ok": true, "stale": false, "attention": false,
                "five": {"pct": 38.0, "reset": 1781153400},
                "week": {"pct": 4.0,  "reset": 1781391600}},
     "codex":  {...}}
    pct = used percent; reset = reset epoch seconds (null once the window has reset)

Privacy:
    Claude data uses your existing Claude Code OAuth token from the macOS keychain to
    call the official read-only usage endpoint. Codex data is parsed entirely from local
    session logs (no network). No credentials ever leave this machine.
"""
import datetime
import glob
import json
import os
import subprocess
import sys
import time
import urllib.request

CACHE_DIR = os.path.expanduser("~/.cache/quotastrip")
CLAUDE_CACHE = os.path.join(CACHE_DIR, "claude.json")
CLAUDE_CACHE_TTL = 600       # s; the usage API is rate-limited (429) and quota changes slowly
CLAUDE_429_COOLDOWN = 900    # base 429 cooldown; exponential backoff on repeated failures
CLAUDE_429_COOLDOWN_MAX = 3600
CLAUDE_STALE_AFTER = 900     # cache older than this counts as "stale" (yellow dot)
FETCH_LOG = os.path.join(CACHE_DIR, "fetch.log")


def log_fetch(msg):
    """Record every real network request (cache hits are not logged). Trims past 256KB."""
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        if os.path.exists(FETCH_LOG) and os.path.getsize(FETCH_LOG) > 262144:
            with open(FETCH_LOG) as f:
                tail = f.readlines()[-1000:]
            with open(FETCH_LOG, "w") as f:
                f.writelines(tail)
        with open(FETCH_LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def dot(pct):
    if pct >= 80:
        return "🔴"
    if pct >= 50:
        return "🟡"
    return "🟢"


def iso_to_epoch(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


# ---------------------------------------------------------------- Claude

def claude_credential():
    """Read the Claude Code OAuth credential from the keychain (read-only)."""
    out = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
        capture_output=True, text=True, timeout=10,
    ).stdout.strip()
    return json.loads(out)["claudeAiOauth"]


def token_expired(cred, now):
    """True if the stored access token is past its expiry (expiresAt is epoch ms)."""
    exp = cred.get("expiresAt")
    return exp is not None and (exp / 1000.0) < (now - 30)  # 30s skew


def degrade_cached(data, now, stale):
    """Adjust cached windows for display when we're serving the cache (live API unavailable):
      - reset time has passed        -> window rolled over; new value unknown -> pct None ("—")
      - stale AND no future reset     -> last success was idle/long ago; current value unknown
    A fresh-enough cache with a valid future reset is shown as-is (still trustworthy)."""
    out = dict(data)
    for key in ("five", "week"):
        w = dict(data[key])
        reset = w.get("reset")
        has_future_reset = reset is not None and reset >= now
        if not has_future_reset and (reset is not None or stale):
            w = {"pct": None, "reset": None}
        out[key] = w
    return out


def claude_fetch(force=False):
    """Return (data, stale); (None, True) on total failure. force=True bypasses cache+cooldown."""
    cached = None
    now = time.time()
    try:
        cached = json.load(open(CLAUDE_CACHE))
    except Exception:
        pass

    def cached_result():
        stale = (now - cached["ts"]) > CLAUDE_STALE_AFTER
        return degrade_cached(cached["data"], now, stale), stale

    if cached and not force and (now - cached["ts"] < CLAUDE_CACHE_TTL
                                 or now < cached.get("cooldown_until", 0)):
        return cached_result()

    # Read the credential and check expiry BEFORE hitting the network: an expired token
    # only earns a 401 that still counts against the rate limit, so don't waste the request.
    try:
        cred = claude_credential()
    except Exception as e:
        log_fetch("keychain read failed: %s" % e)
        if cached:
            return cached_result()
        return None, True

    if token_expired(cred, now):
        log_fetch("token expired — run `claude` or open Claude Code to refresh it")
        if cached:
            return cached_result()
        return None, True

    try:
        req = urllib.request.Request(
            "https://api.anthropic.com/api/oauth/usage",
            headers={
                "Authorization": f"Bearer {cred['accessToken']}",
                "anthropic-beta": "oauth-2025-04-20",
            },
        )
        raw = json.load(urllib.request.urlopen(req, timeout=10))
        data = {
            "five": {"pct": float(raw["five_hour"]["utilization"]),
                     "reset": iso_to_epoch(raw["five_hour"].get("resets_at"))},
            "week": {"pct": float(raw["seven_day"]["utilization"]),
                     "reset": iso_to_epoch(raw["seven_day"].get("resets_at"))},
        }
        os.makedirs(CACHE_DIR, exist_ok=True)
        json.dump({"ts": now, "data": data}, open(CLAUDE_CACHE, "w"))
        log_fetch("ok five=%.0f%% week=%.0f%%" % (data["five"]["pct"], data["week"]["pct"]))
        return data, False
    except urllib.error.HTTPError as e:
        if e.code == 429 and cached:
            # Rate-limited: honor the server's Retry-After (exact unblock time) when present,
            # otherwise fall back to exponential backoff (15min -> 30min -> 60min cap).
            retry_after = None
            try:
                retry_after = int(e.headers.get("retry-after"))
            except (TypeError, ValueError):
                pass
            if retry_after is not None:
                cached["fail_count"] = 0
                cooldown = min(retry_after + 30, CLAUDE_429_COOLDOWN_MAX)
            else:
                fails = cached.get("fail_count", 0) + 1
                cached["fail_count"] = fails
                cooldown = min(CLAUDE_429_COOLDOWN * (2 ** (fails - 1)), CLAUDE_429_COOLDOWN_MAX)
            cached["cooldown_until"] = now + cooldown
            try:
                json.dump(cached, open(CLAUDE_CACHE, "w"))
            except OSError:
                pass
            log_fetch("429 rate-limited retry_after=%s cooldown=%ds" % (retry_after, cooldown))
        else:
            log_fetch("http %d %s" % (e.code, e.reason))
        if cached:
            return cached_result()
        return None, True
    except Exception as e:
        log_fetch("fail %s: %s" % (type(e).__name__, e))  # network down / timeout / keychain etc.
        if cached:
            return cached_result()
        return None, True


# ---------------------------------------------------------------- Codex

def find_rate_limits(path, tail_bytes=262144):
    """Scan a session log backwards from the tail for the last rate_limits record."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        f.seek(max(0, size - tail_bytes))
        chunk = f.read().decode("utf-8", errors="replace")
    for line in reversed(chunk.splitlines()):
        if '"rate_limits"' not in line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        rl = dig(obj, "rate_limits")
        if rl:
            return rl
    return None


def dig(obj, key):
    if isinstance(obj, dict):
        if key in obj and isinstance(obj[key], dict):
            return obj[key]
        for v in obj.values():
            found = dig(v, key)
            if found:
                return found
    return None


def codex_window(window):
    """A window past its reset time has zeroed out and has no reset time."""
    if not window:
        return {"pct": 0.0, "reset": None}
    reset = window.get("resets_at")
    if reset is not None and reset < time.time():
        return {"pct": 0.0, "reset": None}
    return {"pct": float(window.get("used_percent") or 0), "reset": reset}


def codex_fetch():
    pattern = os.path.expanduser("~/.codex/sessions/*/*/*/*.jsonl")
    files = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    latest_mtime = os.path.getmtime(files[0]) if files else None
    for path in files[:5]:
        try:
            rl = find_rate_limits(path)
        except OSError:
            continue
        if rl:
            return {"five": codex_window(rl.get("primary")),
                    "week": codex_window(rl.get("secondary")),
                    "attention": attention_flag("codex", latest_mtime)}
    return None


# ---------------------------------------------------------------- Waiting reminder

WAIT_IDLE_MIN = 15    # log must be idle this long to count as "waiting" (active work updates often)
WAIT_WINDOW = 7200    # sessions idle for >2h no longer alert


def ack_mtime(name):
    """When the user last acknowledged (tapped the Touch Bar panel)."""
    try:
        return os.path.getmtime(os.path.join(CACHE_DIR, name + "_ack"))
    except OSError:
        return 0


def attention_flag(name, activity_mtime=None):
    """Hook-written reminder flag. Cleared once acknowledged (tap) or after new activity (replied)."""
    flag = os.path.join(CACHE_DIR, name + "_attention")
    try:
        flag_mtime = os.path.getmtime(flag)
    except OSError:
        return False
    stale = flag_mtime <= ack_mtime(name) or \
        (activity_mtime is not None and activity_mtime > flag_mtime + 5)
    if stale:
        try:
            os.remove(flag)
        except OSError:
            pass
        return False
    return True


def claude_waiting():
    """Zero-config heuristic (no hooks needed, works for old sessions too): if the most
    recently active session log's last main-chain message is from the assistant and the log
    has gone idle, Claude is waiting for input."""
    files = glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
    if not files:
        return False
    latest = max(files, key=os.path.getmtime)
    mtime = os.path.getmtime(latest)
    age = time.time() - mtime
    if age < WAIT_IDLE_MIN or age > WAIT_WINDOW:
        return False
    if mtime <= ack_mtime("claude"):
        return False
    size = os.path.getsize(latest)
    with open(latest, "rb") as f:
        f.seek(max(0, size - 65536))
        chunk = f.read().decode("utf-8", errors="replace")
    for line in reversed(chunk.splitlines()):
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        # Tool results are logged as type "user", so a trailing "assistant" means waiting
        # (turn finished, or a tool call is waiting for permission confirmation).
        if obj.get("type") in ("user", "assistant") and not obj.get("isSidechain"):
            return obj["type"] == "assistant"
    return False


# ---------------------------------------------------------------- Output

def service_json(data, stale=False, attention=None):
    if data is None:
        return {"ok": False}
    return {"ok": True, "stale": stale, "five": data["five"], "week": data["week"],
            "attention": data.get("attention", attention) or False}


def fmt_text(name, data, stale):
    if data is None:
        return f"{name} --"
    five, week = data["five"]["pct"], data["week"]["pct"]
    mark = "°" if stale else ""
    return f"{dot(max(five, week))}{name} {five:.0f}·{week:.0f}{mark}"


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "json"
    if which == "claude":
        print(fmt_text("CLD", *claude_fetch()))
    elif which == "codex":
        print(fmt_text("CDX", codex_fetch(), False))
    else:
        cl, stale = claude_fetch(force="--force" in sys.argv)
        claude_attn = attention_flag("claude") or claude_waiting()
        print(json.dumps({
            "claude": service_json(cl, stale, attention=claude_attn),
            "codex": service_json(codex_fetch()),
        }))


if __name__ == "__main__":
    main()
