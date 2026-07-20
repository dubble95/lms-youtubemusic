# YouTube Music Plugin for Lyrion Music Server (LMS)

Lyrion Music Server(LMS, 구 Logitech Media Server)에서 YouTube Music을 탐색하고 재생하는 플러그인입니다.

Browse and play music from YouTube Music on your Lyrion Music Server.

## Features / 주요 기능

- **InnerTube API 연동** — YouTube Music 내부 API로 직접 통신 (검색, 홈, 라이브러리, 차트, 앨범/플레이리스트 탐색)
- **쿠키 인증 (단일 방식)** — 브라우저 확장 또는 DevTools로 쿠키 입력. 자동 형식 감지로 `cookies.txt`와 raw Cookie 헤더 모두 지원
- **고음질 오디오** — `yt-dlp`로 최적의 오디오 스트림 추출 (Opus/M4A)
- **메타데이터 지원** — 곡 제목, 아티스트, 앨범, 앨범 아트워크 표시
- **경로 자동 감지** — LMS prefs 디렉토리를 런타임에 자동 감지. 어느 OS/설치 경로에서도 동작

## Installation / 설치

1. 저장소를 다운로드하거나 clone 합니다.
2. `YouTubeMusic` 디렉토리를 LMS `Plugins` 디렉토리에 복사합니다.
   - Linux: 일반적으로 `/var/lib/squeezeboxserver/Plugins`
   - 최종 경로가 `.../Plugins/YouTubeMusic/Plugin.pm` 이 되도록 합니다.
3. LMS를 재시작합니다.
   ```bash
   sudo systemctl restart lyrionmusicserver
   # 또는 구 버전: sudo systemctl restart squeezeboxserver
   ```
4. **Settings → Plugins** 에서 "YouTube Music" 이 활성화되어 있는지 확인합니다.

## Authentication / 인증하기 (필수)

재생하려면 YouTube Music 쿠키가 필요합니다. 두 가지 방법 중 편한 쪽을 선택하세요. **방법 1이 훨씬 쉽습니다.**

> **참고**: 이전 버전의 OAuth2 ("YouTube on TV" 기기 페어링)는 제거되었습니다. YouTube Music의 InnerTube API가 OAuth Bearer 토큰을 거부하기 때문입니다 (익명 호출은 200, OAuth Bearer 호출은 400). 따라서 쿠키 방식만 지원합니다.

### 방법 1 — 브라우저 확장 프로그램 (권장, 가장 쉬움)

개발자 도구를 열 필요 없이 클릭 몇 번으로 쿠키를 얻습니다.

**1. 확장 프로그램 설치**
- Chrome / Edge / Firefox 용 **"Get cookies.txt LOCALLY"** 설치
  - Chrome Web Store: https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc
  - 소스코드 (오픈소스): https://github.com/kairi003/Get-cookies.txt-LOCALLY

  > ⚠️ **경고**: 이름이 비슷한 **"Get cookies.txt"** (끝에 "LOCALLY" 없음)는 **해킹된 적이 있으므로 절대 설치하지 마세요**. 반드시 "LOCALLY" 버전을 설치하세요.

**2. 쿠키 내보내기**
1. 브라우저에서 https://music.youtube.com 을 열고 로그인되어 있는지 확인합니다.
2. 확장 프로그램 아이콘을 클릭합니다.
3. **"Export"** 를 클릭하면 `youtube.com_cookies.txt` 파일이 다운로드됩니다.

**3. LMS에 입력**
1. 다운로드한 `.txt` 파일을 텍스트 에디터로 엽니다.
2. **전체 내용**을 복사합니다 (`# Netscape HTTP Cookie File` 로 시작하는 부분부터 전부).
3. LMS 웹 설정 → **YouTube Music** 설정 페이지의 쿠키 입력칸에 붙여넣습니다.
4. **Save Settings** 를 클릭합니다. 플러그인이 자동으로 `cookies.txt` 형식을 인식해 변환합니다.

---

### 방법 2 — 개발자 도구 (DevTools, 고급)

확장 프로그램을 설치할 수 없는 환경에서 사용합니다.

1. 브라우저에서 https://music.youtube.com 을 열고 로그인합니다.
2. **F12** 키를 눌러 개발자 도구를 엽니다.
3. **Network** (네트워크) 탭을 선택합니다.
4. 페이지에서 아무 링크나 클릭하거나 곡을 재생하여 요청을 발생시킵니다.
5. **`music.youtube.com` 도메인**인 요청 아무거나 클릭합니다.
   - 주의: `www.google.com` 요청이 아닌, 반드시 `music.youtube.com` 요청이어야 합니다.
6. **Headers** → **Request Headers** 에서 `Cookie:` 헤더를 찾아 **전체 값**을 복사합니다.
   - 반드시 `SID`, `HSID`, `SSID`, `SAPISID`, `__Secure-3PSID` 가 모두 포함되어야 합니다.
7. LMS 웹 설정 → **YouTube Music** 설정 페이지에 붙여넣고 **Save Settings** 를 클릭합니다.

> **팁**: 쿠키가 유효하지 않거나 필수 쿠키가 누락된 경우 플러그인 로그에 경고가 기록됩니다. LMS 설정 → 고급 → 로그 설정에서 `plugin.youtubemusic` 카테고리를 `INFO` 이상으로 켜면 확인할 수 있습니다.

---

### 인증 상태 확인

설정 페이지 상단의 **Connection Status** 표시로 현재 인증 상태를 확인할 수 있습니다:
- 🟢 **✓ Connected (cookie configured)** — 정상
- 🔴 **✗ Not authenticated** — 쿠키 입력 필요

## 쿠키가 만료되면?

- **방법 1 (확장)** 로 내보낸 전체 쿠키: 약 2년간 유효합니다.
- 쿠키가 만료되면 위 과정을 다시 수행해서 새 쿠키를 붙여넣으세요.
- 음악이 갑자기 재생되지 않거나 라이브러리가 비어 보인다면 쿠키 갱신을 먼저 시도하세요.

## YouTube Music Premium 안내

- **공개 영상**(일반 유튜브 영상)은 Premium 구독 여부와 무관하게 재생됩니다.
- **음악 전용 트랙**(뮤직 비디오가 없는 음원)은 재생에 **YouTube Music Premium 구독이 필요**합니다.
  - Premium 구독 중인 계정의 쿠키를 입력해야 합니다.
  - Premium 인증이 안 되면 해당 곡에서 yt-dlp가 "Requested format is not available" 에러를 냅니다.

## Dependencies / 의존성

- LMS 8.0 이상
- 시스템 `yt-dlp` (권장, 자동 감지됨) 또는 플러그인에 포함된 `Bin/yt-dlp_*` 바이너리
- Python 3 + `ytmusicapi` (API 호출용)

## 파일 구조 (주요 파일)

| 파일 | 역할 |
|---|---|
| `Plugin.pm` | 진입점, OPML 메뉴 (Search/Home/Explore/Charts/Library) |
| `Settings.pm` | 웹 설정 페이지 핸들러, 쿠키 정규화 |
| `ProtocolHandler.pm` | `ytmusic://` 프로토콜 처리, yt-dlp 스트림 해석 |
| `API.pm` | 검색/탐색 API 호출 (Python 헬퍼 경유) |
| `Utils.pm` | `prefs_dir()` 경로 자동 감지, yt-dlp 바이너리 탐지 |
| `ytm_api.py` | ytmusicapi 실제 API 호출기 |
| `ytm_netscape_to_cookie.py` | cookies.txt ↔ Cookie 헤더 변환 |
| `ytm_auth_refresh.py` | 쿠키로부터 ytmusicapi auth 파일 생성 |
| `HTML/EN/plugins/YouTubeMusic/settings/basic.html` | 웹 설정 UI |

## Acknowledgements / 감사의 글

- `philippe44/LMS-YouTube` 플러그인 아키텍처 기반
- 미디어 추출에 `yt-dlp` 사용
- API 호출에 `ytmusicapi` 사용
