# YouTube Music Plugin for Lyrion Music Server (LMS)

Browse and play music from YouTube Music on your Lyrion Music Server (LMS, formerly Logitech Media Server).

## Features

- **InnerTube API integration** — Communicates directly with the YouTube Music internal API (search, home, library, charts, album/playlist browsing)
- **Cookie authentication (single method)** — Enter cookies via a browser extension or DevTools. Automatic format detection supports both `cookies.txt` and raw Cookie header strings
- **High-quality audio** — Extracts the best audio stream via `yt-dlp` (Opus/M4A)
- **Metadata support** — Displays track title, artist, album, and album artwork
- **Automatic path detection** — Detects the LMS prefs directory at runtime. Works on any OS / install path

## Installation

### Option A — via LMS plugin directory (recommended)

1. In the LMS web UI go to **Settings → Plugins**.
2. At the bottom, add this URL to the **Additional Repositories** box:
   ```
   https://raw.githubusercontent.com/dubble95/lms-youtubemusic/main/public.xml
   ```
3. Click **Apply**. "YouTube Music" will appear in the plugin list — enable it.
4. Restart LMS when prompted.

After future updates, bumping the version in `public.xml` will let users upgrade via **Settings → Plugins** without touching files.

### Option B — manual install

1. Download or clone this repository.
2. Copy the `YouTubeMusic` directory into your LMS `Plugins` directory.
   - Linux: typically `/var/lib/squeezeboxserver/Plugins`
   - The final path should be `.../Plugins/YouTubeMusic/Plugin.pm`
3. Restart LMS:
   ```bash
   sudo systemctl restart lyrionmusicserver
   # or on older installs: sudo systemctl restart squeezeboxserver
   ```
4. Enable "YouTube Music" under **Settings → Plugins**.

## Authentication (required)

Playing music requires YouTube Music cookies. Choose whichever of the two methods below is more convenient. **Method 1 is by far the easiest.**

> **Note**: The previous OAuth2 ("YouTube on TV" device pairing) flow has been removed because the YouTube Music InnerTube API rejects OAuth Bearer tokens (anonymous calls return 200, OAuth Bearer calls return 400). Only cookie-based authentication is supported.

### Method 1 — Browser extension (recommended, easiest)

Get cookies in a few clicks without opening developer tools.

**1. Install the extension**
- Install **"Get cookies.txt LOCALLY"** for Chrome / Edge / Firefox
  - Chrome Web Store: https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc
  - Source code (open source): https://github.com/kairi003/Get-cookies.txt-LOCALLY

  > ⚠️ **Warning**: Do NOT install the similarly-named **"Get cookies.txt"** (without "LOCALLY") — it has been compromised. Always install the "LOCALLY" version.

**2. Export the cookies**
1. Open https://music.youtube.com in your browser and make sure you are logged in.
2. Click the extension icon.
3. Click **"Export"** — a `youtube.com_cookies.txt` file will be downloaded.

**3. Enter them in LMS**
1. Open the downloaded `.txt` file in a text editor.
2. Copy **the entire contents** (starting from `# Netscape HTTP Cookie File`).
3. Paste it into the cookie input box on the **YouTube Music** settings page in the LMS web UI.
4. Click **Save Settings**. The plugin automatically recognizes the `cookies.txt` format and converts it.

---

### Method 2 — Developer tools (DevTools, advanced)

Use this when you cannot install a browser extension.

1. Open https://music.youtube.com in your browser and log in.
2. Press **F12** to open the developer tools.
3. Select the **Network** tab.
4. Click any link or play a track on the page to generate a request.
5. Click any request whose domain is **`music.youtube.com`**.
   - Note: it must be a `music.youtube.com` request, not a `www.google.com` request.
6. Under **Headers** → **Request Headers**, find the `Cookie:` header and copy its **entire value**.
   - It must include `SID`, `HSID`, `SSID`, `SAPISID`, and `__Secure-3PSID`.
7. Paste it into the **YouTube Music** settings page in the LMS web UI and click **Save Settings**.

> **Tip**: If the cookie is invalid or required cookies are missing, a warning is logged by the plugin. You can inspect it by enabling the `plugin.youtubemusic` category at `INFO` level or higher under LMS settings → Advanced → Logging settings.

---

### Checking authentication status

The **Connection Status** indicator at the top of the settings page shows the current state:
- 🟢 **✓ Connected (cookie configured)** — OK
- 🔴 **✗ Not authenticated** — cookie input required

## When cookies expire

- Cookies exported via **Method 1 (extension)** are valid for approximately 2 years.
- When a cookie expires, repeat the steps above to paste a fresh cookie.
- If music suddenly stops playing or the library appears empty, try refreshing the cookie first.

## About YouTube Music Premium

- **Public videos** (regular YouTube videos) play regardless of Premium subscription.
- **Music-only tracks** (audio-only tracks without a music video) require a **YouTube Music Premium subscription** to play.
  - You must enter cookies from a Premium-subscribed account.
  - Without Premium authentication, yt-dlp will fail with "Requested format is not available" on those tracks.

## Dependencies

- LMS 8.0 or newer
- System `yt-dlp` 2026.07 or newer (recommended, auto-detected)
- Python 3 + `ytmusicapi` (for API calls)

### How audio streaming works (no JS runtime needed)

Since late 2025 YouTube enforces **SABR streaming + a JS challenge (n-challenge)** on the *web* client, which previously required QuickJS or Node.js to solve. **This plugin avoids the challenge entirely** by resolving streams with the **Android YouTube app User-Agent** (`com.google.android.youtube/17.29.34`), which bypasses SABR/n-challenge and returns audio-only formats (m4a 128 kbps / opus 160 kbps) directly — no JS runtime, no `yt-dlp-ejs`, no 80-second delay.

This technique was learned from [schmij97/lms-ytmusic](https://github.com/schmij97/lms-ytmusic)'s `ytmproxy.py`.

> **Important**: Cookies are used **only** for API calls (search, browse, library, Supermix) via `ytm_api.py` — not for stream resolution. Passing cookies to the Android client causes YouTube to return "This video is only available to Music Premium members". The split is handled automatically by the plugin.

No QuickJS, Node.js, or `yt-dlp-ejs` installation is required anymore.

## File structure (key files)

| File | Role |
|---|---|
| `Plugin.pm` | Entry point, OPML menu (Search/Home/Explore/Charts/Library) |
| `Settings.pm` | Web settings page handler, cookie normalization |
| `ProtocolHandler.pm` | `ytmusic://` protocol handling, yt-dlp stream resolution |
| `API.pm` | Search/browse API calls (via the Python helper) |
| `Utils.pm` | `prefs_dir()` path auto-detection, yt-dlp binary detection |
| `ytm_api.py` | Actual ytmusicapi caller |
| `ytm_netscape_to_cookie.py` | cookies.txt ↔ Cookie header conversion |
| `ytm_auth_refresh.py` | Generates the ytmusicapi auth file from cookies |
| `HTML/EN/plugins/YouTubeMusic/settings/basic.html` | Web settings UI |

## Acknowledgements

- **[schmij97/lms-ytmusic](https://github.com/schmij97/lms-ytmusic)** — The proxy-based streaming architecture (`ytmproxy.py`), the Android User-Agent technique, and the playlist-protocol-handler pattern were adapted from this project. Their approach of piping yt-dlp through ffmpeg to produce a clean MP3 stream solved the squeezelite moov-atom problem and eliminated the need for QuickJS/Node.js entirely.
- Based on the `philippe44/LMS-YouTube` plugin architecture
- Uses `yt-dlp` for media extraction
- Uses `ytmusicapi` for API calls

## Disclaimer

This project is **not affiliated with, endorsed by, or sponsored by YouTube, Google, or Alphabet**. "YouTube Music" is a trademark of Google LLC.

This is an unofficial plugin that uses the publicly accessible YouTube Music InnerTube API and `yt-dlp` for stream resolution. It does not circumvent any digital rights management (DRM) — it plays content that is already accessible to the authenticated account through a web browser.

- A valid YouTube Music **cookie** from your own account is required for personalisation (search, library, Supermix). Playback of Premium-exclusive tracks requires a Premium subscription.
- The plugin streams audio for **personal, non-commercial use** only. Redistribution, public performance, or commercial use of the streamed content may violate YouTube's Terms of Service.
- The authors are not responsible for any misuse of this software or for any consequences arising from its use.
- This software is provided "as is" without warranty of any kind, under the MIT License.

## License

Released under the [MIT License](LICENSE).
