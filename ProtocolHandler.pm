package Plugins::YouTubeMusic::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTP);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::YouTubeMusic::Utils;
use JSON::XS;
use AnyEvent::Util;

my $log = Slim::Utils::Log::logger('plugin.youtubemusic');
my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');

# Register the protocol handler
Slim::Player::ProtocolHandlers->registerHandler('ytmusic', __PACKAGE__);

sub canDirectStream {
    return 0; # We'll use transcoding/proxying via HTTP redirect for now or custom stream
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $yt_dlp = Plugins::YouTubeMusic::Utils::yt_dlp_bin();
	if (!$yt_dlp) {
        $errorCb->("cannot find yt-dlp");
        return;
    }

	my $url = $song->track()->url;
    my ($id) = $url =~ /ytmusic:\/\/([a-zA-Z0-9_\-]+)/;
    
    if (!$id) {
        $errorCb->("invalid ytmusic ID");
        return;
    }

	my $yt_url = "https://music.youtube.com/watch?v=$id";
    
    $log->info("Getting track info for $id");

    my $cv = AnyEvent::Util::run_cmd(
        [ $yt_dlp, '-j', $yt_url],
        "<", "/dev/null",
        ">" , \my $tracks_json,
        "2>", \my $err,
    );

    $cv->cb( sub {
        my $tracks = eval { decode_json($tracks_json) };

        if ($@ || !$tracks) {
            $log->error("yt-dlp failed: $err");
            $errorCb->($@ || "yt-dlp failed");
            return;
        }

        # duration is in seconds
        $song->track->secs( $tracks->{'duration'} );
        
        # Store metadata for getMetadata
        $song->pluginData(metadata => {
            title    => $tracks->{title},
            artist   => $tracks->{uploader} || $tracks->{artist},
            album    => $tracks->{album},
            duration => $tracks->{duration},
            image    => $tracks->{thumbnail},
        });
        
        # Select best audio format
        my $stream_url = _selectBestAudio($tracks->{formats});
        
        if (!$stream_url) {
            $errorCb->("No suitable audio stream found");
            return;
        }

        $log->info("Stream URL found: $stream_url");
        
        # In a real implementation, we might need to handle expiration and signatures
        # For now, we'll try to just pass the URL
        $song->pluginData(url => $stream_url);
        
        $successCb->();
    });
}

sub _selectBestAudio {
    my $formats = shift;
    
    # Simple selection: find highest bitrate m4a/opus
    my $best_format;
    for my $f (@$formats) {
        next unless $f->{vcodec} eq 'none'; # audio only
        
        if (!$best_format || $f->{abr} > $best_format->{abr}) {
            $best_format = $f;
        }
    }
    
    return $best_format->{url} if $best_format;
    return undef;
}

sub getMetadata {
	my ( $class, $client, $url ) = @_;
    
    if (my $song = $client->playingSong()) {
        if (my $meta = $song->pluginData('metadata')) {
            return $meta;
        }
    }
    
    # Fallback or for non-playing tracks
	return {
		title => 'YouTube Music Track',
	};
}

1;
