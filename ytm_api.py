#!/usr/bin/env python3
"""
YouTube Music API caller for LMS plugin using ytmusicapi.
Usage: python3 ytm_api.py <method> <json_body> [ignored]
"""
import sys
import os
import json
import hashlib
import time
import urllib.request
import urllib.error

AUTH_FILE  = '/var/lib/squeezeboxserver/prefs/plugin/ytmusicapi_auth.json'
AUTH_FILE_OAUTH = '/var/lib/squeezeboxserver/prefs/plugin/ytmusicapi_oauth.json'
PREFS_FILE = '/var/lib/squeezeboxserver/prefs/plugin/youtubemusic.prefs'
API_BASE   = 'https://music.youtube.com/youtubei/v1/'
API_KEY    = 'AIzaSyB-pwPtDkxF6JQmA8qq9h1md60MyI5Q5iA'
CLIENT     = {'clientName': 'WEB_REMIX', 'clientVersion': '1.20230828.01.00'}


# ─── ytmusicapi helpers ────────────────────────────────────────────────────────

def get_ytm():
    """Return authenticated YTMusic instance, or None."""
    try:
        from ytmusicapi import YTMusic
        
        # 1. Try OAuth2 authentication first (permanent login)
        if os.path.exists(AUTH_FILE_OAUTH):
            return YTMusic(AUTH_FILE_OAUTH)
            
        # 2. Fall back to Cookie authentication
        if os.path.exists(AUTH_FILE):
            try:
                # Read current auth JSON
                with open(AUTH_FILE, 'r') as f:
                    auth = json.load(f)
                
                # Extract Cookie to generate a fresh Authorization header
                cookie = auth.get('cookie') or auth.get('Cookie')
                if cookie:
                    # Find SAPISID
                    sapisid = ''
                    for part in cookie.replace(';', ' ;').split(';'):
                        part = part.strip()
                        if part.startswith('SAPISID='):
                            sapisid = part[8:].strip()
                            break
                    
                    if sapisid:
                        # Build a fresh SAPISIDHASH
                        t = int(time.time())
                        h = hashlib.sha1(f'{t} {sapisid} https://music.youtube.com'.encode()).hexdigest()
                        auth_val = f'SAPISIDHASH {t}_{h}_u SAPISID1PHASH {t}_{h}_u SAPISID3PHASH {t}_{h}_u'
                        
                        # Update headers in memory
                        auth['authorization'] = auth_val
                        if 'Authorization' in auth:
                            auth['Authorization'] = auth_val
                        
                        # Write updated auth JSON back to disk
                        with open(AUTH_FILE, 'w') as f:
                            json.dump(auth, f, indent=4)
            except Exception as ex:
                sys.stderr.write(f'Failed to refresh auth header: {ex}\n')

            return YTMusic(AUTH_FILE)
    except Exception as e:
        sys.stderr.write(f'ytmusicapi init error: {e}\n')
    return None


def _thumb(item):
    thumbs = item.get('thumbnails') or []
    return thumbs[-1].get('url', '') if thumbs else ''


def _artist_str(item):
    artists = item.get('artists') or []
    if isinstance(artists, list):
        return ', '.join(a.get('name', '') for a in artists if isinstance(a, dict))
    return str(artists)


def _make_song_item(track):
    """ytmusicapi song → musicResponsiveListItemRenderer-like."""
    video_id = track.get('videoId')
    nav_ep = {'watchEndpoint': {'videoId': video_id}} if video_id else {}
    subtitle = _artist_str(track)
    album = track.get('album') or {}
    if album.get('name'):
        subtitle += f' • {album["name"]}'
    return {'musicResponsiveListItemRenderer': {
        'flexColumns': [
            {'musicResponsiveListItemFlexColumnRenderer': {
                'text': {'runs': [{'text': track.get('title', ''), 'navigationEndpoint': nav_ep}]}
            }},
            {'musicResponsiveListItemFlexColumnRenderer': {
                'text': {'runs': [{'text': subtitle}]}
            }},
        ],
        'navigationEndpoint': nav_ep,
        'thumbnail': {'musicThumbnailRenderer': {
            'thumbnail': {'thumbnails': [{'url': _thumb(track)}]}
        }},
    }}


def _make_browse_item(title, subtitle, browse_id, page_type, thumb_url):
    """browseEndpoint-based item (album, playlist, artist)."""
    nav_ep = {'browseEndpoint': {
        'browseId': browse_id,
        'browseEndpointContextSupportedConfigs': {
            'browseEndpointContextMusicConfig': {'pageType': page_type}
        }
    }}
    return {'musicTwoRowItemRenderer': {
        'title': {'runs': [{'text': title, 'navigationEndpoint': nav_ep}]},
        'subtitle': {'runs': [{'text': subtitle}]},
        'navigationEndpoint': nav_ep,
        'thumbnailRenderer': {'musicThumbnailRenderer': {
            'thumbnail': {'thumbnails': [{'url': thumb_url}]}
        }},
    }}


def _make_playlist_item(item):
    """Playlist / mix with playlistId."""
    pid    = item.get('playlistId', '')
    # YT Music playlists use VLPL... as browseId
    browse_id = 'VL' + pid if pid and not pid.startswith('VL') else pid
    page_type = 'MUSIC_PAGE_TYPE_PLAYLIST'
    return _make_browse_item(
        item.get('title', ''),
        _artist_str(item) or 'Playlist',
        browse_id, page_type, _thumb(item)
    )


def _convert_home(home_data):
    sections = []
    for shelf in (home_data or []):
        if shelf is None:
            continue
        contents = []
        for item in (shelf.get('contents') or []):
            if item is None:
                continue
            try:
                if item.get('videoId'):
                    contents.append(_make_song_item(item))
                elif item.get('playlistId'):
                    contents.append(_make_playlist_item(item))
                elif item.get('browseId'):
                    pt = 'MUSIC_PAGE_TYPE_ALBUM'
                    contents.append(_make_browse_item(
                        item.get('title', ''), _artist_str(item),
                        item['browseId'], pt, _thumb(item)
                    ))
            except Exception as e:
                sys.stderr.write(f'Item conversion error: {e}\n')
                continue
        if contents:
            sections.append({'musicShelfRenderer': {
                'title': {'runs': [{'text': shelf.get('title', '')}]},
                'contents': contents,
            }})
    return _wrap_sections(sections)



def _convert_library_root():
    contents = [
        _make_browse_item('Playlists', 'Your saved playlists', 'FEmusic_library_playlists', 'MUSIC_PAGE_TYPE_LIBRARY', ''),
        _make_browse_item('Albums', 'Your saved albums', 'FEmusic_library_albums', 'MUSIC_PAGE_TYPE_LIBRARY', ''),
        _make_browse_item('Songs', 'Your saved songs', 'FEmusic_library_songs', 'MUSIC_PAGE_TYPE_LIBRARY', ''),
        _make_browse_item('Artists', 'Your subscribed artists', 'FEmusic_library_artists', 'MUSIC_PAGE_TYPE_LIBRARY', ''),
    ]
    return _wrap_sections([{'musicShelfRenderer': {'title': {'runs': [{'text': 'Library'}]}, 'contents': contents}}])


def _convert_library_playlists(playlists):
    contents = []
    for item in (playlists or []):
        contents.append(_make_playlist_item(item))
    return _wrap_sections([{'musicShelfRenderer': {'contents': contents}}])


def _convert_library_albums(albums):
    contents = []
    for item in (albums or []):
        browse_id = item.get('browseId')
        if browse_id:
            contents.append(_make_browse_item(
                item.get('title', ''),
                _artist_str(item) or 'Album',
                browse_id,
                'MUSIC_PAGE_TYPE_ALBUM',
                _thumb(item)
            ))
    return _wrap_sections([{'musicShelfRenderer': {'contents': contents}}])


def _convert_library_artists(artists):
    contents = []
    for item in (artists or []):
        browse_id = item.get('browseId')
        if browse_id:
            contents.append(_make_browse_item(
                item.get('artist', ''),
                'Artist',
                browse_id,
                'MUSIC_PAGE_TYPE_ARTIST',
                _thumb(item)
            ))
    return _wrap_sections([{'musicShelfRenderer': {'contents': contents}}])


def _convert_library_songs(songs):
    contents = []
    for item in (songs or []):
        contents.append(_make_song_item(item))
    return _wrap_sections([{'musicShelfRenderer': {'contents': contents}}])


def _convert_playlist(data):
    tracks = data.get('tracks', [])
    contents = [_make_song_item(t) for t in tracks if t.get('videoId')]
    return _wrap_sections([{'musicShelfRenderer': {
        'title': {'runs': [{'text': data.get('title', 'Playlist')}]},
        'contents': contents,
    }}], layout='sectionList')


def _convert_album(data):
    tracks = data.get('tracks', [])
    artist = data.get('artists') or []
    contents = []
    for t in tracks:
        if not t.get('artists'):
            t['artists'] = artist
        if t.get('videoId'):
            contents.append(_make_song_item(t))
    return _wrap_sections([{'musicShelfRenderer': {
        'title': {'runs': [{'text': data.get('title', 'Album')}]},
        'contents': contents,
    }}], layout='sectionList')


def _convert_artist(data):
    sections = []
    songs = (data.get('songs') or {}).get('results', [])
    if songs:
        sections.append({'musicShelfRenderer': {
            'title': {'runs': [{'text': 'Songs'}]},
            'contents': [_make_song_item(t) for t in songs if t.get('videoId')],
        }})
    albums = (data.get('albums') or {}).get('results', [])
    if albums:
        items = [_make_browse_item(
            a.get('title', ''), str(a.get('year', '')),
            a.get('browseId', ''), 'MUSIC_PAGE_TYPE_ALBUM', _thumb(a)
        ) for a in albums if a.get('browseId')]
        if items:
            sections.append({'musicCarouselShelfRenderer': {
                'header': {'musicCarouselShelfBasicHeaderRenderer': {
                    'title': {'runs': [{'text': 'Albums'}]}
                }},
                'contents': items,
            }})
    return _wrap_sections(sections)


def _convert_search(results):
    shelves = {}
    for item in (results or []):
        rt = item.get('resultType', 'unknown')
        shelves.setdefault(rt, []).append(item)

    sections = []
    for rt in ['song', 'album', 'playlist', 'artist', 'video']:
        items = shelves.get(rt, [])
        if not items:
            continue
        contents = []
        for item in items:
            if rt in ('song', 'video') and item.get('videoId'):
                contents.append(_make_song_item(item))
            elif rt == 'album' and item.get('browseId'):
                contents.append(_make_browse_item(
                    item.get('title', ''), _artist_str(item),
                    item['browseId'], 'MUSIC_PAGE_TYPE_ALBUM', _thumb(item)
                ))
            elif rt == 'playlist' and item.get('browseId'):
                contents.append(_make_browse_item(
                    item.get('title', ''), _artist_str(item),
                    item['browseId'], 'MUSIC_PAGE_TYPE_PLAYLIST', _thumb(item)
                ))
            elif rt == 'artist' and item.get('browseId'):
                contents.append(_make_browse_item(
                    item.get('artist', item.get('title', '')), 'Artist',
                    item['browseId'], 'MUSIC_PAGE_TYPE_ARTIST', _thumb(item)
                ))
        if contents:
            sections.append({'musicShelfRenderer': {
                'title': {'runs': [{'text': rt.capitalize() + 's'}]},
                'contents': contents,
            }})

    return {
        'contents': {'tabbedSearchResultsRenderer': {
            'tabs': [{'tabRenderer': {'content': {
                'sectionListRenderer': {'contents': sections}
            }}}]
        }}
    }


def _wrap_sections(sections, layout='singleColumn'):
    if layout == 'singleColumn':
        return {
            'contents': {'singleColumnBrowseResultsRenderer': {
                'tabs': [{'tabRenderer': {'content': {
                    'sectionListRenderer': {'contents': sections}
                }}}]
            }}
        }
    else:
        return {
            'contents': {'sectionListRenderer': {'contents': sections}}
        }


# ─── Direct API fallback ────────────────────────────────────────────────────────

def get_cookie_from_prefs():
    try:
        with open(PREFS_FILE) as f:
            raw = f.read()
        lines, in_c = [], False
        for l in raw.split('\n'):
            if l.startswith('cookie:'):
                in_c = True; lines.append(l[7:].strip())
            elif in_c and (l.startswith(' ') or l.startswith('\t')):
                lines.append(l.strip())
            elif in_c:
                break
        return ' '.join(lines)
    except Exception:
        return ''


def direct_api_call(method, body):
    cookie = get_cookie_from_prefs()
    if not cookie:
        return {'error': 'No cookie configured'}

    sapisid = ''
    for p in cookie.replace(';', ' ;').split(';'):
        p = p.strip()
        if p.startswith('SAPISID='):
            sapisid = p[8:].strip(); break

    t = int(time.time())
    h = hashlib.sha1(f'{t} {sapisid} https://music.youtube.com'.encode()).hexdigest()
    auth_val = f'SAPISIDHASH {t}_{h}_u SAPISID1PHASH {t}_{h}_u SAPISID3PHASH {t}_{h}_u'

    body['context'] = {'client': CLIENT}
    url = f'{API_BASE}{method}?prettyPrint=false&key={API_KEY}'
    headers = {
        'Content-Type': 'application/json',
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:152.0) Gecko/20100101 Firefox/152.0',
        'Origin': 'https://music.youtube.com',
        'X-Origin': 'https://music.youtube.com',
        'X-Goog-AuthUser': '0',
        'Cookie': cookie,
        'Authorization': auth_val,
        'Referer': 'https://music.youtube.com/',
    }
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {'error': str(e)}


# ─── Main ──────────────────────────────────────────────────────────────────────

def main():
    method   = sys.argv[1] if len(sys.argv) > 1 else 'browse'
    body_str = sys.argv[2] if len(sys.argv) > 2 else '{}'

    try:
        body = json.loads(body_str)
    except Exception as e:
        sys.stdout.write(json.dumps({'error': f'Invalid JSON: {e}'}))
        return

    ytm = get_ytm()
    result = None

    if ytm:
        try:
            if method == 'browse':
                browse_id = body.get('browseId', '')
                if browse_id == 'FEmusic_home':
                    result = _convert_home(ytm.get_home(limit=25))
                elif browse_id == 'FEmusic_library_library':
                    result = _convert_library_root()
                elif browse_id == 'FEmusic_library_playlists':
                    result = _convert_library_playlists(ytm.get_library_playlists(limit=50))
                elif browse_id == 'FEmusic_library_albums':
                    result = _convert_library_albums(ytm.get_library_albums(limit=50))
                elif browse_id == 'FEmusic_library_artists':
                    result = _convert_library_artists(ytm.get_library_artists(limit=50))
                elif browse_id == 'FEmusic_library_songs':
                    result = _convert_library_songs(ytm.get_library_songs(limit=100))
                elif browse_id.startswith('VL') or browse_id.startswith('RDAMPL'):
                    result = _convert_playlist(ytm.get_playlist(browse_id[2:] if browse_id.startswith('VL') else browse_id, limit=50))
                elif browse_id.startswith('MPREb_') or (len(browse_id) > 10 and browse_id[0].isupper() and '_' not in browse_id[:6]):
                    try:
                        result = _convert_album(ytm.get_album(browse_id))
                    except Exception:
                        result = _convert_playlist(ytm.get_playlist(browse_id, limit=50))
                elif browse_id.startswith('UC'):
                    result = _convert_artist(ytm.get_artist(browse_id))
                elif browse_id in ('FEmusic_explore', 'FEmusic_charts', 'FEmusic_new_releases'):
                    # Fall through to direct API for these
                    pass
                else:
                    # Try as playlist first, then album
                    try:
                        result = _convert_playlist(ytm.get_playlist(browse_id, limit=50))
                    except Exception:
                        try:
                            result = _convert_album(ytm.get_album(browse_id))
                        except Exception:
                            pass
            elif method == 'search':
                query = body.get('query', '')
                if query:
                    result = _convert_search(ytm.search(query, limit=20))
        except Exception as e:
            sys.stderr.write(f'ytmusicapi error: {e}\n')
            result = None

    # Fallback to direct API call
    if result is None:
        sys.stderr.write(f'Falling back to direct API for {method}\n')
        result = direct_api_call(method, body)

    sys.stdout.write(json.dumps(result))


if __name__ == '__main__':
    main()
