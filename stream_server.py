#!/usr/bin/env python3
"""Serves the live scene and a single /api/overview endpoint."""
import csv
import io
import json
import os
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8765"))
STATE_GIST = os.environ.get("STATE_GIST", "d2a685e5fa684c1123c9369df5ddf824")

BACKTEST = {
    "return_pct": 154374.0,
    "years": 6.6,
    "pos_months": 60,
    "total_months": 79,
}


_GIST_CACHE = {"ts": 0, "data": {}}
_CACHE_TTL = 120


def _fetch_api(gist_id):
    req = urllib.request.Request(
        f"https://api.github.com/gists/{gist_id}",
        headers={"User-Agent": "live-scene", "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        d = json.loads(resp.read())
    return {fn: f.get("content", "") for fn, f in (d.get("files") or {}).items()}


def read_gist(gist_id):
    import time
    now = time.time()
    if _GIST_CACHE["data"] and now - _GIST_CACHE["ts"] < _CACHE_TTL:
        return _GIST_CACHE["data"]
    for attempt in range(3):
        try:
            data = _fetch_api(gist_id)
            if data:
                _GIST_CACHE["ts"] = now
                _GIST_CACHE["data"] = data
                return data
        except Exception:
            time.sleep(2 * (attempt + 1))
    return _GIST_CACHE["data"]


def parse_trades(csv_content, eth_only=True):
    rows = list(csv.DictReader(io.StringIO(csv_content)))
    closes = []
    for r in rows:
        if r.get("action") != "CLOSE" or not r.get("pnl"):
            continue
        try:
            price = float(r.get("price", 0) or 0)
            pnl = float(r["pnl"])
        except ValueError:
            continue
        if eth_only and price >= 10000:
            continue
        try:
            equity = float(r.get("equity", 0) or 0)
        except ValueError:
            equity = 0.0
        eq_before = equity - pnl
        ret = pnl / eq_before if eq_before > 0 else 0.0
        closes.append({"ts": r.get("ts", ""), "side": r.get("side", ""),
                       "price": price, "pnl": pnl, "ret": ret})
    return closes


def compute_stats(closes):
    n = len(closes)
    if n == 0:
        return {"trades": 0, "wr": 0, "pf": 0}
    wins = [c for c in closes if c["pnl"] > 0]
    gross_win = sum(c["pnl"] for c in wins)
    gross_loss = -sum(c["pnl"] for c in closes if c["pnl"] < 0)
    pf = (gross_win / gross_loss) if gross_loss > 0 else (gross_win if gross_win > 0 else 0)
    return {"trades": n, "wr": round(len(wins) / n * 100, 1), "pf": round(pf, 2)}


def returns_summary(closes):
    if not closes:
        return {"total_pct": 0, "weekly_pct": 0, "monthly_pct": 0, "days": 0}
    factor = 1.0
    for c in closes:
        factor *= (1 + c["ret"])
    total_pct = (factor - 1) * 100
    try:
        first = datetime.fromisoformat(closes[0]["ts"])
        last = datetime.fromisoformat(closes[-1]["ts"])
        days = max((last - first).days, 1)
    except Exception:
        days = 1
    return {
        "total_pct": round(total_pct, 2),
        "weekly_pct": round(total_pct / days * 7, 2),
        "monthly_pct": round(total_pct / days * 30, 2),
        "days": days,
    }


def snapshot():
    files = read_gist(STATE_GIST)
    state_file = next((c for fn, c in files.items() if fn.endswith(".json")), None)
    trades_file = next((c for fn, c in files.items() if fn.endswith(".csv")), None)

    out = {"ok": bool(files), "position": None, "days_running": None, "bot_start": None,
           "stats": compute_stats([]), "history": [],
           "returns": {"total_pct": 0, "weekly_pct": 0, "monthly_pct": 0, "days": 0}}

    if state_file:
        try:
            st = json.loads(state_file)
        except Exception:
            st = {}
        pm = st.get("position_meta") or st.get("position")
        if pm:
            out["position"] = {
                "side": pm.get("side", "?"),
                "entry": pm.get("entry_price"),
                "sl": pm.get("stop_loss"),
                "tp": pm.get("take_profit"),
            }
        bs = st.get("bot_start")
        if bs:
            out["bot_start"] = bs
            try:
                out["days_running"] = (datetime.now(timezone.utc) - datetime.fromisoformat(bs)).days
            except Exception:
                pass

    if trades_file:
        closes = parse_trades(trades_file, eth_only=True)
        out["stats"] = compute_stats(closes)
        out["returns"] = returns_summary(closes)
        cum = 0.0
        hist = []
        for c in parse_trades(trades_file, eth_only=False):
            cum += c["pnl"]
            asset = "ETH" if c["price"] < 10000 else "BTC"
            hist.append({**c, "cum": round(cum, 4), "asset": asset})
        out["history"] = hist

    return out


def build_overview():
    return {
        "real": snapshot(),
        "backtest_hist": BACKTEST,
        "updated": datetime.now(timezone.utc).strftime("%H:%M:%S UTC"),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body, ctype="application/json; charset=utf-8", code=200):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _serve_file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                self._send(f.read(), ctype)
        except FileNotFoundError:
            self._send("not found", "text/plain", 404)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/live", "/live.html"):
            self._serve_file("live_scene.html", "text/html; charset=utf-8")
        elif path == "/api/overview":
            try:
                self._send(json.dumps(build_overview()))
            except Exception as e:
                self._send(json.dumps({"error": str(e)}), code=500)
        else:
            self._send("not found", "text/plain", 404)


if __name__ == "__main__":
    read_gist(STATE_GIST)
    print(f"Live scene on http://127.0.0.1:{PORT}/live")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
