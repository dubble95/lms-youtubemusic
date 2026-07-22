package Plugins::YouTubeMusic::API;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::SimpleAsyncHTTP;

my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');
my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');

# ── Proxy-based API ───────────────────────────────────────────────────────────
# All calls go through the local Python proxy (ytmproxy.py) started by Plugin.pm.
# The proxy handles the YouTube Music InnerTube API with cookies for
# personalisation and yt-dlp for stream resolution.

sub _proxy_url {
    my $port = $prefs->get('proxy_port') || 9876;
    return "http://127.0.0.1:$port";
}

sub _get {
    my ($path, $cb) = @_;

    my $url = _proxy_url() . $path;
    $log->info("API GET: $url");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { decode_json($http->content) };
            if ($@) {
                $log->error("JSON decode error for $url: $@");
                $cb->(undef);
            } else {
                $cb->($data);
            }
        },
        sub {
            my ($http, $err) = @_;
            $log->error("Proxy request failed ($url): $err");
            $cb->(undef);
        },
        { timeout => 30 }
    )->get($url);
}

sub search {
    my ($class, $cb, $query) = @_;
    my $q = URI::Escape::uri_escape_utf8($query // '');
    _get("/search?q=$q", $cb);
}

sub browse {
    my ($class, $cb, $browse_id) = @_;
    _get("/browse?browseId=" . URI::Escape::uri_escape_utf8($browse_id // ''), $cb);
}

sub browseHome       { $_[0]->_get_cb('/browse/home', $_[1]) }
sub browseCharts     { $_[0]->_get_cb('/browse/charts', $_[1]) }
sub browseNewReleases { $_[0]->_get_cb('/browse/new_releases', $_[1]) }
sub browseMoods      { $_[0]->_get_cb('/browse/moods', $_[1]) }

sub _get_cb {
    my ($class, $path, $cb) = @_;
    _get($path, $cb);
}

sub getSongInfo {
    my ($class, $video_id, $cb) = @_;
    _get("/song?videoId=$video_id", $cb);
}

sub prefetch {
    my ($class, $video_id, $cb) = @_;
    $cb ||= sub {};
    _get("/prefetch/$video_id", $cb);
}

sub browseRadio {
    my ($class, $video_id, $cb) = @_;
    _get("/radio?videoId=$video_id", $cb);
}

# watch_playlist is used by Radio.pm and PlaylistProtocolHandler.pm.
# Map it to the proxy's /radio (for radio seeds) or /browse (for playlists).
sub watch_playlist {
    my ($class, $cb, $seed_ref) = @_;
    if ($seed_ref->{videoId}) {
        _get("/radio?videoId=" . URI::Escape::uri_escape_utf8($seed_ref->{videoId}), $cb);
    } elsif ($seed_ref->{playlistId}) {
        _get("/browse?browseId=" . URI::Escape::uri_escape_utf8($seed_ref->{playlistId}), $cb);
    } else {
        $cb->([]);
    }
}

1;
