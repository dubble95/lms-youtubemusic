package Plugins::YouTubeMusic::PlaylistProtocolHandler;

# Handles ytmplaylist://<browseId> URLs by expanding them into individual
# ytmusic://<videoId> tracks at queueing time.

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::YouTubeMusic::API;

my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');
my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');

Slim::Player::ProtocolHandlers->registerHandler('ytmplaylist', __PACKAGE__);

use Plugins::YouTubeMusic::ProtocolHandler;

sub isRemote         { return 1; }
sub contentType      { return 'aac'; }
sub canDirectStream  { return 0; }

# After explodePlaylist converts ytmplaylist:// → ytmusic:// tracks, LMS still
# calls getNextTrack on *this* handler for the first track in the expanded list
# because the original URL was ytmplaylist://. Delegate to ProtocolHandler so
# yt-dlp resolution happens correctly.
sub getNextTrack {
    my ($class, @args) = @_;
    return Plugins::YouTubeMusic::ProtocolHandler->getNextTrack(@args);
}

sub getMetadataFor {
    my ($class, @args) = @_;
    return Plugins::YouTubeMusic::ProtocolHandler->getMetadataFor(@args);
}

sub explodePlaylist {
    my ($class, $client, $url, $cb) = @_;

    my ($browse_id) = $url =~ /ytmplaylist:(?:\/\/)?(.+)/;
    unless ($browse_id) {
        $log->error("invalid ytmplaylist URL: $url");
        $cb->([]);
        return;
    }

    $log->info("Exploding playlist: $browse_id");

    # Ask the YouTube Music API for the playlist contents. Use watch_playlist
    # with the playlist id — it returns { tracks => [...], playlistId => ... }.
    Plugins::YouTubeMusic::API->watch_playlist(sub {
        my $resp = shift;

        # The API helper returns a hash with a 'tracks' array or an array of items.
        my $tracks = [];
        if (ref($resp) eq 'HASH') {
            $tracks = $resp->{tracks} || [];
        } elsif (ref($resp) eq 'ARRAY') {
            $tracks = $resp;
        }

        unless (ref($tracks) eq 'ARRAY' && @$tracks) {
            $log->error("Playlist $browse_id returned no tracks");
            $cb->([]);
            return;
        }

        $log->info("Playlist $browse_id: resolved " . scalar(@$tracks) . " tracks");

        my @track_urls;
        require Slim::Utils::Cache;
        my $cache = Slim::Utils::Cache->new();

        for my $t (@$tracks) {
            next unless $t->{videoId};

            my $t_url = "ytmusic://$t->{videoId}";
            push @track_urls, $t_url;

            # Prime metadata for every track so that getMetadataFor is
            # immediately populated for the play queue.
            $cache->set("ytm:meta:$t_url", {
                title    => $t->{title}    || '',
                artist   => $t->{artist}   || '',
                album    => $t->{album}    || '',
                cover    => $t->{thumbnail} || '',
                duration => $t->{duration} || 0,
            }, 86400);
        }

        $cb->(\@track_urls);
    }, { playlistId => $browse_id, limit => 200, radio => 0 });
}

1;
