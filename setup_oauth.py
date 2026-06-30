#!/usr/bin/env python3
"""
ytmusicapi OAuth2 setup script for LMS YouTubeMusic plugin.
Run once on the Pi to authenticate and save OAuth2 credentials.

Usage: python3 setup_oauth.py
"""
import os
import sys

AUTH_FILE = '/var/lib/squeezeboxserver/prefs/plugin/ytmusicapi_oauth.json'

def main():
    try:
        from ytmusicapi import YTMusic
        from ytmusicapi.auth.oauth import OAuthCredentials
    except ImportError:
        print("Installing ytmusicapi...")
        os.system("pip3 install ytmusicapi")
        from ytmusicapi import YTMusic

    print("=" * 60)
    print("YouTube Music OAuth2 Setup for LMS Plugin")
    print("=" * 60)
    print()

    if os.path.exists(AUTH_FILE):
        print(f"Auth file already exists: {AUTH_FILE}")
        ans = input("Re-authenticate? [y/N]: ").strip().lower()
        if ans != 'y':
            print("Keeping existing auth file.")
            return

    print("Starting OAuth2 device flow authentication...")
    print("A URL will be shown below. Open it in your browser")
    print("and log in with your YouTube Music Premium account.")
    print()

    try:
        YTMusic.setup_oauth(filepath=AUTH_FILE, open_browser=False)
        print()
        print("✅ Authentication successful!")
        print(f"   Credentials saved to: {AUTH_FILE}")
        print()
        print("Verify by testing get_home()...")

        ytm = YTMusic(AUTH_FILE)
        home = ytm.get_home(limit=2)
        print(f"✅ Home returned {len(home)} sections — plugin ready!")
        for s in home[:2]:
            print(f"   - {s.get('title')}: {len(s.get('contents', []))} items")

    except Exception as e:
        print(f"❌ OAuth2 setup failed: {e}")
        print()
        print("Trying browser cookie method instead...")
        print("Please paste the Cookie header value from Chrome DevTools:")
        cookie = input("Cookie: ").strip()
        if cookie:
            _setup_browser_auth(cookie)

def _setup_browser_auth(cookie):
    import hashlib, time, json
    from ytmusicapi import YTMusic

    HEADER_FILE = '/var/lib/squeezeboxserver/prefs/plugin/ytmusicapi_auth.json'

    sapisid = ''
    for p in cookie.replace(';', ' ;').split(';'):
        p = p.strip()
        if p.startswith('SAPISID='): sapisid = p[8:].strip(); break

    t = int(time.time())
    h = hashlib.sha1(f'{t} {sapisid} https://music.youtube.com'.encode()).hexdigest()
    auth_val = f'SAPISIDHASH {t}_{h}'

    raw_headers = f'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36\nContent-Type: application/json\nAccept: */*\nAccept-Language: en-US,en;q=0.9\nAuthorization: {auth_val}\nCookie: {cookie}\nX-Goog-AuthUser: 0\nx-origin: https://music.youtube.com\n'

    YTMusic.setup(filepath=HEADER_FILE, headers_raw=raw_headers)
    print(f'Auth file written: {HEADER_FILE}')

    # Also update the LMS prefs cookie
    prefs_file = '/var/lib/squeezeboxserver/prefs/plugin/youtubemusic.prefs'
    if os.path.exists(prefs_file):
        with open(prefs_file) as f:
            lines = f.readlines()
        new_lines = []
        skip_next = False
        for line in lines:
            if line.startswith('cookie:'):
                new_lines.append(f'cookie: {cookie}\n')
                skip_next = True
            elif skip_next and (line.startswith(' ') or line.startswith('\t')):
                continue
            else:
                skip_next = False
                new_lines.append(line)
        with open(prefs_file, 'w') as f:
            f.writelines(new_lines)
        print(f'LMS prefs cookie updated')

if __name__ == '__main__':
    main()
