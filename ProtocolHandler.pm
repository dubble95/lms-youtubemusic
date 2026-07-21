package Plugins::YouTubeMusic::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::YouTubeMusic::Utils;
use JSON::XS::VersionOneAndTwo;
use AnyEvent::Util;

my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');
my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');

# Register the protocol handler
Slim::Player::ProtocolHandlers->registerHandler('ytmusic', __PACKAGE__);

sub isRemote         { return 1; }
sub contentType      { return 'aac'; }  # fallback, overridden per-track
sub getFormatForURL  { return 'aac'; }  # tells LMS to treat as audio stream

sub new {
    my ($class, $args) = @_;
    my $song = $args->{song};
    
    my $url = $song->pluginData('url');
    if ($url) {
        $args->{url} = $url;
        $log->info("Redirecting RemoteStream URL to: $url");
    }
    
    return $class->SUPER::new($args);
}

sub formatOverride {
    my ($class, $song) = @_;
    my $meta = $song->pluginData('metadata') || {};
    return $meta->{type} || 'aac';
}

sub canDirectStream {
    my ($class, $client, $url) = @_;
    $log->warn("canDirectStream checked for url: $url - returning 0");
    return 0;
}

sub canDirectStreamSong {
    my ($class, $client, $song) = @_;
    $log->warn("canDirectStreamSong checked - returning 0");
    return 0;
}

sub forceTranscode {
    my ($class, $client, $format) = @_;
    $log->warn("forceTranscode checked for format: $format - returning 1");
    return 1;
}

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

sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;

    my $yt_dlp = Plugins::YouTubeMusic::Utils::yt_dlp_bin();
    if (!$yt_dlp) {
        $log->error("Cannot find yt-dlp binary");
        $errorCb->("cannot find yt-dlp");
        return;
    }

    $log->info("Using yt-dlp: $yt_dlp");

    my $url = $song->track()->url;
    my ($id) = $url =~ /ytmusic:\/\/([a-zA-Z0-9_\-]+)/;

    if (!$id) {
        $errorCb->("invalid ytmusic ID from URL: $url");
        return;
    }

    my $yt_url = "https://music.youtube.com/watch?v=$id";
    $log->info("Getting track info for: $yt_url");

    # Build yt-dlp command
    my @cmd = ($yt_dlp, '--no-warnings', '--quiet', '--extractor-args', 'youtube:player_client=web,default', '-j', $yt_url);

    # Pass cookies via a Netscape cookies.txt file rather than --add-header.
    # yt-dlp's cookie jar handles domain/path/secure matching and __Secure-/
    # __Host- semantics correctly per sub-request, which a static header cannot.
    # Prefer the verbatim cookies.txt the user pasted (cookie_raw pref) since
    # it preserves the original secure/expiry/domain attributes; fall back to
    # deriving a Netscape file from the normalized Cookie header otherwise.
    my $cookie_raw  = $prefs->get('cookie_raw');
    my $cookie_str  = $prefs->get('cookie');
    if ($cookie_raw || $cookie_str) {
        my $cookies_file = _write_cookies_file($cookie_raw, $cookie_str);
        if ($cookies_file) {
            push @cmd, '--cookies', $cookies_file;
            $log->info("Passing cookies via --cookies $cookies_file (raw len: " . length($cookie_raw // '0') . ")");
        } elsif ($cookie_str) {
            # Fallback to header if file write failed.
            push @cmd, '--add-header', "Cookie:$cookie_str";
            $log->warn("Falling back to --add-header (cookie file write failed)");
        }
    }

    my $cv = AnyEvent::Util::run_cmd(
        \@cmd,
        "<",  "/dev/null",
        ">",  \my $tracks_json,
        "2>", \my $err,
    );

    $cv->cb(sub {
        # Strip any non-JSON lines before the actual JSON (e.g. yt-dlp deprecation warnings)
        my $json_str = $tracks_json // '';
        if ($json_str =~ /^(.*?)(\{.+)$/s) {
            $json_str = $2;  # Take only from first '{'
        }

        my $tracks = eval { decode_json($json_str) };

        if ($@ || !$tracks) {
            $log->error("yt-dlp failed for $id: $err");
            $log->error("yt-dlp stdout was: " . substr($tracks_json || '', 0, 200));
            $errorCb->($@ || "yt-dlp failed: $err");
            return;
        }

        # Store metadata. Prefer the largest thumbnail from the 'thumbnails'
        # array for crisp cover art; fall back to the single 'thumbnail' field.
        my $cover = _pick_best_thumbnail($tracks);

        $song->pluginData(metadata => {
            title    => $tracks->{title},
            artist   => $tracks->{artist} || $tracks->{uploader} || $tracks->{channel},
            album    => $tracks->{album},
            duration => $tracks->{duration},
            image    => $cover,
        });

        # Set track duration + persist cover URL on the track row so the
        # artwork shows up for the currently playing item too.
        eval {
            $song->track->secs($tracks->{duration}) if $tracks->{duration};
            $song->track->cover($cover) if $cover && $song->track->can('cover');
            $song->track->update if $song->track->in_storage;
        };

        # Also refresh the url-keyed metadata cache so getMetadataFor stays
        # consistent with what yt-dlp returned (richer than the radio metadata).
        require Slim::Utils::Cache;
        Slim::Utils::Cache->new()->set("ytm:meta:" . $song->track()->url, {
            title    => $tracks->{title},
            artist   => $tracks->{artist} || $tracks->{uploader} || $tracks->{channel},
            album    => $tracks->{album},
            cover    => $cover,
            duration => $tracks->{duration},
        }, 86400);

        # Select best audio format
        # Must have: vcodec=none, real acodec (not 'none'), real ext (not 'mhtml'), and a URL
        my $formats = $tracks->{formats} || [];
        my @audio_formats = grep {
            my $f = $_;
            ($f->{vcodec} || '') eq 'none'
            && $f->{acodec} && $f->{acodec} ne 'none'
            && ($f->{ext} || '') ne 'mhtml'
            && $f->{url}
        } @$formats;

        if (!@audio_formats) {
            $log->error("No audio-only formats found for $id, trying any format with audio");
            # Fallback: any format that has an audio codec and URL
            @audio_formats = grep { $_->{acodec} && $_->{acodec} ne 'none' && $_->{url} } @$formats;
        }

        if (!@audio_formats) {
            $errorCb->("No suitable audio stream found for $id");
            return;
        }

        # Sort by preference: opus/webm (251) > m4a (140) > then by bitrate
        my @sorted = sort {
            my $a_score = _formatScore($a);
            my $b_score = _formatScore($b);
            $b_score <=> $a_score;
        } @audio_formats;

        my $best = $sorted[0];

        $log->info(sprintf("Selected format %s (%s, %skbps) for %s",
            $best->{format_id} // '?',
            $best->{ext}       // '?',
            $best->{abr}       // '?',
            $id));

        # Update metadata with codec info
        my $meta = $song->pluginData('metadata') || {};
        $meta->{type}    = 'aac';
        $meta->{bitrate} = ($best->{abr} || 0) * 1000;
        $song->pluginData(metadata => $meta);

        $song->pluginData(url => $best->{url});
        $successCb->();
    });
}

# Pick the largest thumbnail URL from a yt-dlp info dict. yt-dlp exposes
# 'thumbnails' (array of {url,width,height,...}) and a single 'thumbnail'.
# Prefer the highest-resolution entry for crisp cover art.
sub _pick_best_thumbnail {
    my $tracks = shift;
    my $best_url;
    my $best_score = -1;

    my $thumbs = $tracks->{thumbnails};
    if (ref($thumbs) eq 'ARRAY') {
        for my $t (@$thumbs) {
            next unless ref($t) eq 'HASH' && $t->{url};
            # Prefer entries that look like cover art (not storyboard entries).
            next if ($t->{url} // '') =~ /_storyboard/i;
            my $score = ($t->{width} || 0) * ($t->{height} || 0);
            # Heavily prefer non-preference-resized default URLs.
            $score += 1_000_000 if ($t->{url} // '') =~ /maxresdefault/;
            if ($score > $best_score) {
                $best_score = $score;
                $best_url   = $t->{url};
            }
        }
    }

    return $best_url || $tracks->{thumbnail} || '';
}

sub _formatScore {
    my $fmt = shift;
    my $score = 0;

    # Prefer audio-only
    $score += 100 if ($fmt->{vcodec} || '') eq 'none';

    # Prefer known high-quality format IDs
    my $fid = $fmt->{format_id} // '';
    $score += 60 if $fid eq '140'; # m4a 128kbps (aac) - highest native compatibility
    $score += 40 if $fid eq '251'; # opus 160kbps (webm)
    $score += 30 if $fid eq '250'; # opus 70kbps
    $score += 20 if $fid eq '249'; # opus 50kbps
    $score += 10 if $fid eq '139'; # m4a 48kbps (aac)

    # Add bitrate score (capped)
    my $abr = $fmt->{abr} || 0;
    $score += ($abr > 200 ? 200 : $abr) / 10;

    return $score;
}

# Write the user's cookies to a Netscape cookies.txt file in the plugin prefs
# dir and return the file path. Returns undef on failure. If the user pasted a
# verbatim cookies.txt (cookie_raw pref), write it as-is so the original
# secure/expiry/domain attributes are preserved; otherwise derive a Netscape
# file from the normalized Cookie header.
sub _write_cookies_file {
    my ($cookie_raw, $cookie_str) = @_;

    require Plugins::YouTubeMusic::Utils;
    require File::Spec::Functions;

    my $dir = Plugins::YouTubeMusic::Utils::prefs_dir();
    return undef unless $dir && -d $dir;

    my $file = File::Spec::Functions::catfile($dir, 'ytm_cookies.txt');

    my $content;
    if ($cookie_raw && _looks_like_netscape($cookie_raw)) {
        # User pasted a real cookies.txt — use it verbatim.
        $content = $cookie_raw;
        $content .= "\n" unless $content =~ /\n$/;
    } elsif ($cookie_str) {
        $content = _cookiesToNetscape($cookie_str);
    } else {
        return undef;
    }

    eval {
        open(my $fh, '>', $file) or die "open: $!";
        print $fh $content;
        close($fh);
        chmod(0600, $file);
    };
    if ($@) {
        $log->warn("Failed to write cookies file $file: $@");
        return undef;
    }

    return $file;
}

# Heuristic: does this text look like a Netscape cookies.txt blob?
sub _looks_like_netscape {
    my $text = shift;
    return 0 unless defined $text;
    return 1 if $text =~ /#.*netscape.*cookie/i;
    # Or: at least 3 lines with 7 tab-separated fields.
    my $tab_lines = 0;
    for my $ln (split /\n/, $text) {
        $tab_lines++ if $ln !~ /^#/ && $ln =~ /\t/ && (scalar(split /\t/, $ln) >= 7);
    }
    return $tab_lines >= 3 ? 1 : 0;
}

# Convert browser cookie string to Netscape cookie file format
sub _cookiesToNetscape {
    my $cookie_str = shift;

    my $header = "# Netscape HTTP Cookie File\n# This file is generated by LMS YouTubeMusic plugin\n\n";
    my @lines;

    # Parse semicolon-separated cookies
    my @parts = split(/;\s*/, $cookie_str);
    for my $part (@parts) {
        $part =~ s/^\s+|\s+$//g;
        next unless $part;
        my ($name, $value) = split(/=/, $part, 2);
        next unless defined $name && defined $value;
        $name  =~ s/^\s+|\s+$//g;
        $value =~ s/^\s+|\s+$//g;

        # Netscape format: domain  flag  path  secure  expiry  name  value
        # YouTube sets these as Secure cookies (sent only over HTTPS):
        # __Secure-*/__Host-* (required by spec), plus SAPISID/SSID family.
        my $secure = ($name =~ /^__Secure-/ || $name =~ /^__Host-/
                   || $name eq 'SAPISID'   || $name eq 'APISID'
                   || $name eq 'SSID'      || $name eq 'SIDCC'
                   || $name eq 'LOGIN_INFO') ? 'TRUE' : 'FALSE';
        push @lines, ".youtube.com\tTRUE\t/\t$secure\t2147483647\t$name\t$value";
        push @lines, ".music.youtube.com\tTRUE\t/\t$secure\t2147483647\t$name\t$value";
    }

    return $header . join("\n", @lines) . "\n";
}

sub getMetadataFor {
    my ($class, $client, $url) = @_;

    if ($client) {
        my $song = $client->playingSong();
        if ($song && $song->track()->url eq $url) {
            if (my $meta = $song->pluginData('metadata')) {
                return {
                    title    => $meta->{title},
                    artist   => $meta->{artist},
                    album    => $meta->{album},
                    cover    => $meta->{image},
                    bitrate  => $meta->{bitrate} ? sprintf('%d kbps', $meta->{bitrate} / 1000) : undef,
                    type     => $meta->{type},
                    duration => $meta->{duration},
                    icon     => $meta->{image},
                };
            }
        }
    }

    # Fallback for queued (not-yet-playing) tracks: look up the metadata the
    # Radio auto-queue stashed in the url-keyed cache, then merge in whatever
    # the DB track holds (title/secs/cover).
    require Slim::Utils::Cache;
    my $cache  = Slim::Utils::Cache->new();
    my $cached = $cache->get("ytm:meta:$url");

    my $track = Slim::Schema->objectForUrl($url);

    if ($cached || $track) {
        my $title    = ($cached && $cached->{title})    || ($track ? $track->title : undef) || 'YouTube Music';
        my $artist   = ($cached && $cached->{artist})   || ($track && $track->can('artistName') ? $track->artistName : undef);
        my $album    = ($cached && $cached->{album})    || ($track && $track->can('albumName') ? $track->albumName : undef);
        my $duration = ($cached && $cached->{duration}) || ($track ? $track->secs : undef);
        my $cover    = ($cached && $cached->{cover})    || ($track && $track->can('cover') ? $track->cover : undef);
        return {
            title    => $title,
            artist   => $artist,
            album    => $album,
            cover    => $cover,
            icon     => $cover,
            duration => $duration,
        };
    }

    return { title => 'YouTube Music Track' };
}

1;
