package Plugins::YouTubeMusic::ProtocolHandler;

# Implements the ytmusic:// protocol scheme for Lyrion Music Server.
#
# Flow:
#   1. LMS calls getNextTrack() when a ytmusic://VIDEO_ID URL is about to play.
#   2. We point the track at our local Python proxy's /stream/VIDEO_ID
#      endpoint (http://127.0.0.1:PORT/stream/VIDEO_ID), which internally
#      pipes yt-dlp's output through ffmpeg to produce a clean MP3 stream.
#      This avoids moov-atom-at-end-of-file issues that prevent squeezelite
#      from playing raw YouTube CDN MP4/WebM.
#   3. Since the proxy is local plain HTTP, we extend the base HTTP handler
#      (no TLS needed) and just substitute the stream URL in new().
#
# The proxy is started/stopped by Plugin.pm (_start_proxy / shutdownPlugin).

use strict;
use warnings;
use base qw(Slim::Player::Protocols::HTTP);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Network;
use Slim::Player::Playlist;
use Slim::Player::Source;

use Plugins::YouTubeMusic::API;

my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');
my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');

# In-memory metadata cache keyed by video ID — warmed by Radio/Playlist
# auto-queue so getMetadataFor returns real titles without a flash of the
# raw video ID.
my %_metadata_cache;

Slim::Player::ProtocolHandlers->registerHandler('ytmusic', __PACKAGE__);

# ── Capability declarations ──────────────────────────────────────────────────

sub isRemote        { 1 }
sub isAudio         { 1 }
sub isAudioURL      { 1 }
sub canSeek         { 0 }
sub canDirectStream { 0 }
sub songBytes       {}

# Audio format — the proxy transcodes to lossless FLAC via ffmpeg for max audio quality
sub formatOverride  { 'flc' }
sub getFormatForURL { 'flc' }
sub contentType     { 'flc' }

# Override scanUrl to prevent Slim::Utils::Scanner::Remote from trying
# to fetch ytmusic:// as an HTTP URL. Just pass the track back immediately.
sub scanUrl {
    my ($class, $url, $args) = @_;
    my $cb = $args->{cb} or return;
    my $track = Slim::Schema->objectForUrl($url) || Slim::Schema->updateOrCreate({
        url => $url,
    });
    $cb->($track, undef, @{$args->{passthrough} || []});
}

# Substitute the local proxy stream URL before the base class opens the
# socket. Without this, LMS treats the ytmusic:// video ID as a hostname
# and fails DNS resolution. Same pattern as RadioParadise's handler.
sub new {
    my $class  = shift;
    my $args   = shift;
    my $song   = $args->{song};

    my $streamUrl = $song ? $song->streamUrl() : undef;
    unless ($streamUrl) {
        $log->error('No resolved stream URL available for ' . ($args->{url} // 'unknown'));
        return undef;
    }

    $args->{url} = $streamUrl;
    $log->warn("Opening local proxy stream: $streamUrl");

    return $class->SUPER::new({
        url    => $streamUrl,
        song   => $song,
        client => $args->{client},
    });
}

# Extract video ID from ytmusic:// URL
sub _extract_video_id {
    my ($url) = @_;
    my ($vid) = $url =~ m{ytmusic://([A-Za-z0-9_\-]+)};
    return $vid;
}

# ── Main resolution ───────────────────────────────────────────────────────────

sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $url = $song->track()->url;
    my $vid = _extract_video_id($url);

    unless ($vid) {
        $log->error("Unrecognised URL: $url");
        $errorCb->('Invalid YouTube Music URL');
        return;
    }

    my $port      = $prefs->get('proxy_port') || 9876;
    # Use the real LMS server address so players on separate machines can
    # fetch the stream directly.
    my $server_ip = Slim::Utils::Network::serverAddr() || '127.0.0.1';
    my $streamUrl = "http://$server_ip:$port/stream/$vid";

    $log->warn("Routing playback through local proxy: $streamUrl");

    $song->streamUrl($streamUrl);

    # Kick off a non-blocking metadata fetch (title/artist/artwork)
    _fetch_metadata($vid, $song);

    $successCb->();

    # Prefetch check — prime the proxy for the next track so its yt-dlp
    # resolution starts early.
    _prefetch_with_client($song);
}

# ── Prefetch ──────────────────────────────────────────────────────────────────

sub _prefetch_with_client {
    my ($song) = @_;

    my $client = eval { $song->master() } || eval { $song->client() };
    return unless $client;

    my $cur_index = eval { Slim::Player::Source::playingSongIndex($client) };
    return unless defined $cur_index;

    my $next_index = $cur_index + 1;
    my $count      = eval { Slim::Player::Playlist::count($client) } || 0;
    return unless $next_index < $count;

    my $next_track = eval { Slim::Player::Playlist::track($client, $next_index) };
    return unless $next_track;

    my $next_url = eval { $next_track->url } // '';
    my ($next_vid) = $next_url =~ m{ytmusic://([A-Za-z0-9_\-]+)};
    return unless $next_vid;

    $log->info("Prefetching next track: $next_vid");
    Plugins::YouTubeMusic::API->prefetch($next_vid, sub {});
}

# ── Metadata ──────────────────────────────────────────────────────────────────

# Called synchronously by Plugin.pm / PlaylistProtocolHandler.pm with data
# we already have from search/browse results, so the cache is warm before LMS
# ever needs it.
sub primeMetadata {
    my ($class, $video_id, $info) = @_;
    return unless $video_id && $info;

    $_metadata_cache{$video_id} ||= {
        title    => $info->{title}     || '',
        artist   => $info->{artist}    || '',
        album    => $info->{album}     || '',
        duration => $info->{duration}  || 0,
        cover    => $info->{thumbnail} || $info->{cover} || '',
    };
}

sub _fetch_metadata {
    my ($video_id, $song) = @_;

    Plugins::YouTubeMusic::API->getSongInfo($video_id, sub {
        my $info = shift;
        return unless $info && ref $info eq 'HASH';

        $_metadata_cache{$video_id} = {
            title    => $info->{title}     || '',
            artist   => $info->{artist}    || '',
            album    => $info->{album}     || '',
            duration => $info->{duration}  || 0,
            cover    => $info->{thumbnail} || $info->{cover} || '',
        };

        my $track = $song->currentTrack();
        $track->title($info->{title})        if $info->{title};
        $track->secs($info->{duration})      if $info->{duration};
        $track->coverurl($info->{thumbnail}) if $info->{thumbnail};
        $track->update();

        Slim::Control::Request::notifyFromArray(undef, ['newmetadata']);
        $log->info("Metadata updated for $video_id: " . ($info->{title} // '?'));
    });
}

# getMetadataFor — called when building Now Playing info
sub getMetadataFor {
    my ($class, $client, $url) = @_;

    my ($vid) = $url =~ m{ytmusic://([A-Za-z0-9_\-]+)};
    return {} unless $vid;

    my $cached = $_metadata_cache{$vid};

    my %meta = (
        title   => ($cached && $cached->{title})  ? $cached->{title}  : "YouTube Music - $vid",
        artist  => ($cached && $cached->{artist}) ? $cached->{artist} : '',
        album   => ($cached && $cached->{album})  ? $cached->{album}  : ' | YouTube Music',
        cover   => ($cached && $cached->{cover})  ? $cached->{cover}
                    : Plugins::YouTubeMusic::Plugin->_pluginDataFor('icon'),
        type    => 'YouTube Music',
        bitrate => '192k CBR',
        duration => ($cached && $cached->{duration}) ? $cached->{duration} : undef,
    );

    return \%meta;
}

sub getIcon {
    return Plugins::YouTubeMusic::Plugin->_pluginDataFor('icon');
}

1;
