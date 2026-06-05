# YouTube Music Plugin for Lyrion Music Server (LMS)

This plugin allows you to browse and play music from YouTube Music on your Lyrion Music Server (formerly Logitech Media Server).

## Features

- **InnerTube API Integration**: Direct communication with YouTube Music's internal API.
- **OAuth2 Authentication**: Easy account linking using the "YouTube on TV" device pairing method.
- **Cookie Authentication**: Alternative authentication using browser cookies for full library access.
- **High-Quality Audio**: Uses `yt-dlp` to extract the best available audio streams (Opus/M4A).
- **Metadata Support**: Displays track titles, artists, albums, and artwork.

## Installation

1.  Download the repository.
2.  Copy the `YouTubeMusic` directory to your LMS `Plugins` directory.
    - On Linux, this is typically `/var/lib/squeezeboxserver/Plugins`.
    - **Note**: Ensure the final path is `.../Plugins/YouTubeMusic/Plugin.pm`.
3.  Restart your Lyrion Music Server.
4.  Go to **Settings -> Plugins** and ensure "YouTube Music" is enabled.

## Authentication

### Method 1: OAuth2 (Recommended)
1.  Go to the YouTube Music plugin settings in the LMS web interface.
2.  Click **"Get Activation Code"**.
3.  Go to [google.com/device](https://www.google.com/device) and enter the displayed code.
4.  Once authorized, click **"I have entered the code"** in LMS settings to complete the process.

### Method 2: Cookie
1.  Log in to [music.youtube.com](https://music.youtube.com) in your browser.
2.  Open Developer Tools (F12) -> Network tab.
3.  Find a request to `browse` or `search`, copy the `Cookie` header value.
4.  Paste it into the **Cookie Authentication** box in LMS settings and save.

## Dependencies

- This plugin includes `yt-dlp` binaries for various platforms.
- Requires LMS 8.0 or higher.

## Acknowledgements

- Based on the architecture of the LMS-YouTube plugin by philippe44.
- Uses `yt-dlp` for media extraction.

---
Developed with Gemini CLI.
