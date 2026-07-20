#!/usr/bin/env python3
"""
Regenerate ytmusicapi auth file from a browser cookie string.
Called by Settings.pm when user saves new cookie in LMS Settings UI.
Usage: python3 ytm_auth_refresh.py "<cookie_string>" [prefs_dir]

prefs_dir is the LMS plugin prefs directory (where plugin/youtubemusic.prefs
lives). It is supplied by Settings.pm via $prefs->dir so the path is resolved
portably. If not provided, falls back to the env var LMS_PREFS_DIR, then to the
historical Debian default.
"""
import sys
import os
import hashlib
import time

DEFAULT_PREFS_DIR = '/var/lib/squeezeboxserver/prefs/plugin'


def _prefs_dir():
    if len(sys.argv) >= 3 and sys.argv[2]:
        return sys.argv[2]
    env = os.environ.get('LMS_PREFS_DIR')
    if env:
        return env
    return DEFAULT_PREFS_DIR


def main():
    if len(sys.argv) < 2:
        print("ERROR: cookie string required as argument")
        sys.exit(1)

    cookie = sys.argv[1].strip().replace('\r', '').replace('\n', ' ')
    if len(cookie) < 50:
        print("ERROR: cookie string too short")
        sys.exit(1)

    AUTH_FILE = os.path.join(_prefs_dir(), 'ytmusicapi_auth.json')

    # Extract SAPISID for SAPISIDHASH
    sapisid = ''
    for part in cookie.replace(';', ' ;').split(';'):
        part = part.strip()
        if part.startswith('SAPISID='):
            sapisid = part[8:].strip()
            break

    if not sapisid:
        print("ERROR: SAPISID not found in cookie")
        sys.exit(1)

    # Build fresh SAPISIDHASH (new format with _u suffix)
    t = int(time.time())
    h = hashlib.sha1(f'{t} {sapisid} https://music.youtube.com'.encode()).hexdigest()
    auth_val = f'SAPISIDHASH {t}_{h}_u SAPISID1PHASH {t}_{h}_u SAPISID3PHASH {t}_{h}_u'

    raw_headers = (
        "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:152.0) "
        "Gecko/20100101 Firefox/152.0\n"
        "Accept: */*\n"
        "Accept-Language: ko-KR,en-US;q=0.9,en;q=0.8\n"
        "Content-Type: application/json\n"
        "X-Goog-AuthUser: 0\n"
        "X-Origin: https://music.youtube.com\n"
        f"Authorization: {auth_val}\n"
        "Origin: https://music.youtube.com\n"
        f"Cookie: {cookie}\n"
    )

    try:
        import ytmusicapi
        ytmusicapi.setup(filepath=AUTH_FILE, headers_raw=raw_headers)
        print(f"OK: ytmusicapi auth file written to {AUTH_FILE}")
    except Exception as e:
        print(f"ERROR: ytmusicapi setup failed: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
