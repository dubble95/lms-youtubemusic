package Plugins::YouTubeMusic::Radio;

# Endless-radio: when a YouTube Music track is playing, automatically append
# YouTube Music's recommended "Up Next / radio" tracks to the play queue so
# playback never runs out.
#
# Strategy:
#   - Subscribe to playlist notifications.
#   - Whenever the current ytmusic:// track changes, kick off a background
#     fetch of the radio playlist seeded from that videoId and append the
#     returned tracks (SEED_BATCH) to the queue.
#   - When the remaining queue (after the current track) drops below the
#     LOW_WATER_MARK, fetch another batch seeded from the LAST track in the
#     queue (or reuse the playlistId returned by the previous fetch) and
#     append. This keeps playback endless without blocking the player thread.
#   - A per-client "refilling" guard prevents concurrent duplicate fetches.
#
# All network calls go through Plugins::YouTubeMusic::API (async), so the
# player is never blocked.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Player::Playlist;
use Slim::Player::Source;
use Slim::Schema;
use Slim::Control::Request;

use Plugins::YouTubeMusic::API;

my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');
my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');

use constant {
    LOW_WATER_MARK => 3,   # refill when fewer than this many tracks remain
    SEED_BATCH     => 10,  # how many tracks to fetch per radio call
    REFILL_BATCH   => 10,
};

my $subscribed = 0;

# Per-client transient state. Keyed on $client->id.
#   last_seed      => videoId we most recently seeded from
#   radio_playlist => playlistId returned by last get_watch_playlist (continuity)
#   refilling      => truthy while a background fetch is in flight
my %state;

sub init {
    my $class = shift;
    return if $subscribed;    # idempotent
    Slim::Control::Request::subscribe(\&_onPlaylistChange, [['playlist']]);
    $subscribed = 1;
    $log->info('YouTube Music radio auto-queue initialized');
}

# ─── helpers ────────────────────────────────────────────────────────────────

sub _ytm_url {
    my $video_id = shift;
    return "ytmusic://$video_id";
}

# Extract the videoId from a ytmusic:// URL, or undef if not one of ours.
sub _video_id_from_url {
    my $url = shift || '';
    my ($id) = $url =~ /ytmusic:\/\/([a-zA-Z0-9_\-]+)/;
    return $id;
}

# Return the list of URLs currently in the playlist. songs() returns Track
# objects; we coerce each to its url string. Also handle the case where the
# underlying playlist stores bare URL strings (some LMS versions / remote
# tracks). Returns an arrayref (never undef).
sub _playlist_urls {
    my $client = shift;
    my @urls;
    my $count = Slim::Player::Playlist::count($client);
    return \@urls unless $count;

    my @songs = Slim::Player::Playlist::songs($client, 0, $count - 1);
    for my $s (@songs) {
        next unless defined $s;
        if (ref($s) && UNIVERSAL::can($s, 'url')) {
            push @urls, $s->url || '';
        } else {
            # Bare URL string.
            push @urls, "$s";
        }
    }
    return \@urls;
}

# Is the currently-playing track (or the queue as a whole) ours?
sub _queue_is_ours {
    my $client = shift;
    my $urls = _playlist_urls($client);
    return 0 unless @$urls;
    # If any of the remaining tracks is ytmusic://, treat the session as ours.
    for my $url (@$urls) {
        return 1 if _video_id_from_url($url);
    }
    return 0;
}

sub _remaining_count {
    my $client = shift;
    my $total  = Slim::Player::Playlist::count($client);
    my $cur    = Slim::Player::Source::playingSongIndex($client) // 0;
    my $remaining = $total - $cur - 1;
    return $remaining < 0 ? 0 : $remaining;
}

# Build a Slim::Schema::Track for a ytmusic:// URL (created lazily; the
# ProtocolHandler's scanUrl/getNextTrack will resolve the stream later).
# Stash the full radio metadata in pluginData on the track so getMetadataFor
# can return title/artist/album/cover for queued (not-yet-playing) tracks too.
sub _track_for_video {
    my ($video_id, $meta) = @_;
    my $url = _ytm_url($video_id);

    my $track;
    eval { $track = Slim::Schema->objectForUrl({ url => $url, create => 1, commit => 1 }); };
    if (!$track) {
        eval { $track = Slim::Schema->updateOrCreate({ url => $url }); };
    }
    return $track unless $track && $meta;

    eval {
        $track->title($meta->{title})   if $meta->{title}    && $track->can('title');
        $track->secs($meta->{duration}) if $meta->{duration} && $track->can('secs');
        # Store the cover-art URL on the track so LMS artwork resolution finds
        # it via getMetadataFor's fallback for queued tracks.
        if ($meta->{thumbnail} && $track->can('cover')) {
            $track->cover($meta->{thumbnail});
        }
        $track->update if $track->in_storage;
    };

    # Also stash artist/album in the track's pluginData namespace so the
    # metadata fallback can surface them without DB foreign-key rows.
    # We attach it to the track's url-scoped cache to survive across requests.
    if ($meta->{artist} || $meta->{album}) {
        my $cache = Slim::Utils::Cache->new();
        $cache->set("ytm:meta:$url", {
            artist => $meta->{artist} || '',
            album  => $meta->{album}  || '',
            title  => $meta->{title}  || '',
            cover  => $meta->{thumbnail} || '',
            duration => $meta->{duration},
        }, 86400);
    }

    return $track;
}

# Append a batch of recommended tracks to the client's queue.
sub _append_tracks {
    my ($client, $tracks_ref) = @_;
    return unless $tracks_ref && @$tracks_ref;

    my @tracks;
    my @video_ids;
    for my $t (@$tracks_ref) {
        my $vid = $t->{videoId} or next;
        my $track = _track_for_video($vid, $t);
        if ($track) {
            push @tracks, $track;
            push @video_ids, $vid;
        }
    }
    return unless @tracks;

    eval {
        Slim::Player::Playlist::addTracks($client, \@tracks, 0);
        Slim::Control::Request::notifyFromArray($client, ['playlist', 'tracks']);
    };
    if ($@) {
        $log->error("Radio: addTracks failed: $@");
        return;
    }

    $log->info(sprintf('Radio: appended %d tracks to %s queue', scalar(@tracks), $client->id));
    return \@video_ids;
}

# Kick off an async radio fetch and append. $seed_video_id wins over the
# stored radio playlistId. Respects the per-client refilling guard.
sub _fetch_and_append {
    my ($client, $seed_video_id, $seed_playlist_id) = @_;
    return unless $client;

    my $cid = $client->id;
    return if $state{$cid}{refilling};   # already in flight

    my $body;
    if ($seed_video_id) {
        $body = { videoId => $seed_video_id, limit => SEED_BATCH, radio => 1 };
    } elsif ($seed_playlist_id || $state{$cid}{radio_playlist}) {
        $body = {
            playlistId => ($seed_playlist_id || $state{$cid}{radio_playlist}),
            limit      => REFILL_BATCH,
        };
    } else {
        $log->warn("Radio: no seed available for $cid, skipping refill");
        return;
    }

    $state{$cid}{refilling} = 1;

    Plugins::YouTubeMusic::API->watch_playlist(sub {
        my $result = shift;
        $state{$cid}{refilling} = 0;

        if (!$result || $result->{error}) {
            $log->warn('Radio: watch_playlist failed: ' . ($result ? $result->{error} : 'no result'));
            return;
        }

        # Save the radio playlistId for continuity on subsequent refills.
        if ($result->{playlistId}) {
            $state{$cid}{radio_playlist} = $result->{playlistId};
        }

        my $n = $result->{tracks} ? scalar(@{$result->{tracks}}) : 0;
        return unless $n;

        my $appended = _append_tracks($client, $result->{tracks});
        if ($appended && @$appended) {
            $state{$cid}{last_video_id} = $appended->[-1];
        }
    }, $body);
}

# ─── playlist change handler ────────────────────────────────────────────────

sub _onPlaylistChange {
    my $request = shift;
    my $client  = $request->client() or return;
    return unless ref($client) && UNIVERSAL::isa($client, 'Slim::Player::Client');

    # Only act when the queue is (or recently became) ours.
    return unless _queue_is_ours($client);

    # Auto-enable only when the cookie is configured — without auth, the
    # radio API returns nothing useful.
    my $cookie = $prefs->get('cookie');
    return unless $cookie && length($cookie) > 50;

    my $cid = $client->id;

    # What is currently playing?
    my $cur_song = eval { $client->playingSong() };
    my $cur_url  = $cur_song ? ($cur_song->track->url || '') : '';
    my $cur_vid  = _video_id_from_url("$cur_url");

    # Update seed tracking and reset continuity on a new track play.
    if ($cur_vid && ($state{$cid}{last_seed} || '') ne $cur_vid) {
        $state{$cid}{last_seed} = $cur_vid;
        $state{$cid}{radio_playlist} = undef;   # fresh radio chain per seed
        $log->info("Radio: seed updated to new track $cur_vid");
    }

    # Refill case: queue is running low.
    my $remaining = _remaining_count($client);
    if ($remaining < LOW_WATER_MARK) {
        $log->info("Radio: queue low ($remaining remaining), refilling");
        my $urls     = _playlist_urls($client);
        my $last_url = $urls->[-1] || '';
        my $last_vid = _video_id_from_url($last_url);
        _fetch_and_append($client, $last_vid || undef, undef);
    }
}

1;
