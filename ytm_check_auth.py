#!/usr/bin/env python3
import sys, json, os, time, hashlib, urllib.request

cookie_file = os.environ.get("YTM_COOKIE_FILE", "/var/lib/squeezeboxserver/prefs/plugin/ytm_cookies.txt")
if not os.path.isfile(cookie_file):
    print("INVALID")
    sys.exit(0)

try:
    pairs = []
    sapisid = None
    with open(cookie_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"): continue
            parts = line.split("\t")
            if len(parts) >= 7:
                k, v = parts[5], parts[6]
                pairs.append(f"{k}={v}")
                if k in ("SAPISID", "__Secure-3PAPISID"):
                    sapisid = v
    cookie_str = "; ".join(pairs)
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Content-Type": "application/json",
        "Cookie": cookie_str,
    }
    if sapisid:
        now = str(int(time.time()))
        inp = f"{now} {sapisid} https://music.youtube.com"
        sapisid_hash = hashlib.sha1(inp.encode()).hexdigest()
        headers["Authorization"] = f"SAPISIDHASH {now}_{sapisid_hash}"

    body = json.dumps({"context": {"client": {"clientName": "WEB_REMIX", "clientVersion": "1.20240918.01.00"}}, "browseId": "FEmusic_liked_playlists"}).encode()
    req = urllib.request.Request("https://music.youtube.com/youtubei/v1/browse?prettyPrint=false", data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = json.loads(resp.read().decode())
        params = data.get("responseContext", {}).get("serviceTrackingParams", [])
        for p in params:
            for kv in p.get("params", []):
                if kv.get("key") == "logged_in" and kv.get("value") == "1":
                    print("VALID")
                    sys.exit(0)
except Exception:
    pass

print("INVALID")
