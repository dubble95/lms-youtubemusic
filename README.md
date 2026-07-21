# YouTube Music Plugin for Lyrion Music Server (LMS)

Browse and play music from YouTube Music on your Lyrion Music Server (LMS, formerly Logitech Media Server).

## Features

- **InnerTube API integration** — Communicates directly with the YouTube Music internal API (search, home, library, charts, album/playlist browsing)
- **Cookie authentication (single method)** — Enter cookies via a browser extension or DevTools. Automatic format detection supports both `cookies.txt` and raw Cookie header strings
- **High-quality audio** — Extracts the best audio stream via `yt-dlp` (Opus/M4A)
- **Metadata support** — Displays track title, artist, album, and album artwork
- **Automatic path detection** — Detects the LMS prefs directory at runtime. Works on any OS / install path

## Installation

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
- System `yt-dlp` (recommended, auto-detected) or the bundled `Bin/yt-dlp_*` binary
- Python 3 + `ytmusicapi` (for API calls)

### Additional requirements for Premium music playback (important)

Since late 2025, YouTube enforces **SABR streaming + a JS challenge (n-challenge)**. Playing Premium-exclusive music tracks therefore requires a **JS runtime and the EJS challenge solver**. If you only play public videos you can skip this setup, but listening to YouTube Music's music-only tracks (most songs) requires the installation below.

**Recommended: use QuickJS** (especially well-suited to memory-constrained environments like Raspberry Pi)

QuickJS is a ~5 MB binary and uses roughly 1/18th the memory of Node (~90 MB), making it stable on low-memory devices such as the Pi Zero 2 W.

```bash
# 1. Compile QuickJS from source (requires gcc)
sudo apt-get install -y gcc make
cd /tmp
wget https://github.com/bellard/quickjs/archive/refs/heads/master.tar.gz -O qjs.tar.gz
tar xzf qjs.tar.gz
cd quickjs-master

# On armv7l (32-bit Pi) you must add -latomic
sed -i 's/^LIBS=-lm -lpthread/LIBS=-lm -lpthread -latomic/' Makefile
sed -i 's/HOST_LIBS=-lm -ldl -lpthread/HOST_LIBS=-lm -ldl -lpthread -latomic/' Makefile

make qjs
sudo cp qjs /usr/local/bin/qjs
sudo chmod 755 /usr/local/bin/qjs
qjs -e "console.log(42)"  # should print 42

# 2. Install yt-dlp-ejs (the challenge solver)
sudo pip3 install -U yt-dlp-ejs

# 3. Verify
yt-dlp --js-runtimes quickjs --verbose --list-formats "https://music.youtube.com/watch?v=<videoId>"
# Success looks like:
#   [debug] JS runtimes: quickjs-<version>
#   [debug] [youtube] [jsc] JS Challenge Providers: ... quickjs
```

> **Alternative: Node.js 22 or newer** — On x86_64/aarch64 where compiling QuickJS is awkward, install Node 22+ and make it accessible at `/usr/local/bin/node`. Note that on a Pi Zero 2 W (422 MB RAM) Node's memory footprint is excessive, so QuickJS is recommended. To switch, change `--js-runtimes quickjs` to `--js-runtimes node` in the plugin's `ProtocolHandler.pm`.

Without this setup, only public videos will play; Premium music tracks will be skipped with a "Requested format is not available" error.

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

- Based on the `philippe44/LMS-YouTube` plugin architecture
- Uses `yt-dlp` for media extraction
- Uses `ytmusicapi` for API calls
