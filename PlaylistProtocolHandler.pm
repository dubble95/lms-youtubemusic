package Plugins::YouTubeMusic::PlaylistProtocolHandler;

# Handles ytmplaylist://<browseId> URLs. When LMS encounters such a URL in the
# playlist, it calls getNextTrack() which:
#   1. Fetches the playlist contents (track list) via the YouTube Music API
#   2. Replaces the placeholder URL with the first track's ytmusic:// URL
#   3. Appends the remaining tracks to the playlist queue
#
# This lets users press "Play" on a playlist / Supermix / album entry from the
# browse menu and have the whole thing queued, instead of only being able to
# navigate into it.

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Player::Playlist;
use Slim::Player::Source;
use JSON::XS::VersionOneAndTwo;

use Plugins::YouTubeMusic::ProtocolHandler;
use Plugins::YouTubeMusic::API;

my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');
my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');

Slim::Player::ProtocolHandlers->registerHandler('ytmplaylist', __PACKAGE__);

sub isRemote         { return 1; }
sub contentType      { return 'aac'; }
sub getFormatForURL  { return 'aac'; }

# Defer everything to the regular track handler once we've expanded the
# playlist into individual ytmusic:// tracks.
sub formatOverride { $_[1] ? $_[1]->pluginData('metadata')->{type} : 'aac' }
sub canDirectStream { 0 }

sub scanUrl {
    my ($class, $url, $args) = @_;
    my $cb = $args->{cb} or return;
    my $track = Slim::Schema->objectForUrl($url) || Slim::Schema->updateOrCreate({ url => $url });
    $cb->($track, undef, @{$args->{passthrough} || []});
}

sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $url = $song->track()->url;
    my ($browse_id) = $url =~ /ytmplaylist:\/\/(.+)/;
    unless ($browse_id) {
        $errorCb->("invalid ytmplaylist URL: $url");
        return;
    }

    $log->info("Expanding playlist: $browse_id");

    my $client = eval { $song->master() } || eval { $song->client() };
    unless ($client) {
        $errorCb->("no client for playlist expansion");
        return;
    }

    # Ask the YouTube Music API for the playlist contents. Use watch_playlist
    # with the playlist id — it returns { tracks => [...], playlistId => ... }.
    Plugins::YouTubeMusic::API->watch_playlist(sub {
        my $resp = shift;

        # The API helper returns a hash with a 'tracks' array. Be defensive in
        # case the shape changes or an error slipped through.
        my $tracks = (ref($resp) eq 'HASH') ? ($resp->{tracks} || []) : [];

        unless (ref($tracks) eq 'ARRAY' && @$tracks) {
            $log->error("Playlist $browse_id returned no tracks");
            $errorCb->("playlist $browse_id is empty");
            return;
        }

        # The first track becomes the current song — swap its URL in place.
        my $first = $tracks->[0];
        my $first_vid = $first->{videoId};
        unless ($first_vid) {
            $errorCb->("playlist $browse_id: first track has no videoId");
            return;
        }

        $log->info("Playlist $browse_id: " . scalar(@$tracks) . " tracks, starting with $first_vid");

        # Rewrite the current song's URL to the first track so the regular
        # ytmusic:// handler resolves it. We have to update the track row too,
        # because getNextTrack reads url from $song->track()->url.
        my $new_url = "ytmusic://$first_vid";
        eval { $song->track->url($new_url); $song->track->update if $song->track->in_storage; };

        # Prime metadata for the first track from the playlist data so the
        # Now Playing screen doesn't flash the raw video id.
        require Slim::Utils::Cache;
        Slim::Utils::Cache->new()->set("ytm:meta:$new_url", {
            title    => $first->{title}    || '',
            artist   => $first->{artist}   || '',
            album    => $first->{album}    || '',
            cover    => $first->{thumbnail} || '',
            duration => $first->{duration} || 0,
        }, 86400);

        # Append the remaining tracks to the queue so they play in order.
        # Use 'playlist add' so LMS inserts them after the current position
        # rather than at the very end (which could be far away if the queue
        # already had a lot of radio tracks).
        my $cur_index = eval { Slim::Player::Source::playingSongIndex($client) } // 0;
        my $insert_at = $cur_index + 1;

        for my $i (1 .. $#$tracks) {
            my $t = $tracks->[$i];
            next unless $t->{videoId};

            my $t_url = "ytmusic://$t->{videoId}";

            # Prime metadata for every queued track.
            Slim::Utils::Cache->new()->set("ytm:meta:$t_url", {
                title    => $t->{title}    || '',
                artist   => $t->{artist}   || '',
                album    => $t->{album}    || '',
                cover    => $t->{thumbnail} || '',
                duration => $t->{duration} || 0,
            }, 86400);

            $client->execute(['playlist', 'insert', $t_url, $insert_at]);
            $insert_at++;
        }

        # Now hand control to the regular ytmusic:// handler for the first track.
        Plugins::YouTubeMusic::ProtocolHandler->getNextTrack($song, $successCb, $errorCb);
    }, { playlistId => $browse_id, limit => 200, radio => 0 });
}

1;
