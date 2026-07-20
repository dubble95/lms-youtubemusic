package Plugins::YouTubeMusic::API;

use strict;

use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use AnyEvent::Util;
use Plugins::YouTubeMusic::Utils;

my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');
my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');

# Path to the Python API helper script
sub _api_script {
    my $plugin_info = Slim::Utils::PluginManager->allPlugins->{'YouTubeMusic'};
    if ($plugin_info && $plugin_info->{'basedir'}) {
        return $plugin_info->{'basedir'} . '/ytm_api.py';
    }
    return '/usr/share/squeezeboxserver/Plugins/YouTubeMusic/ytm_api.py';
}

sub browse {
    my ($class, $cb, $browse_id, $params) = @_;
    my $body = { browseId => $browse_id };
    $body->{params} = $params if $params;
    _call('browse', $body, $cb);
}

sub search {
    my ($class, $cb, $query, $params) = @_;
    my $body = { query => $query };
    $body->{params} = $params if $params;
    _call('search', $body, $cb);
}

# Fetch YouTube Music's radio / "Up Next" recommendations for endless playback.
# $seed_ref = { videoId => '...', playlistId => '...', limit => 25, radio => 1 }
sub watch_playlist {
    my ($class, $cb, $seed_ref) = @_;
    _call('watch_playlist', $seed_ref || {}, $cb);
}

sub _call {
    my ($method, $body, $cb) = @_;

    my $cookie = $prefs->get('cookie') // '';
    $cookie =~ s/[\r\n]//g;

    my $script   = _api_script();
    my $body_str = to_json($body);

    $log->warn("API calling $method via Python script (cookie length: " . length($cookie) . ")");

    # Tell the Python helper where the LMS plugin prefs dir is so it does not
    # have to hardcode /var/lib/squeezeboxserver/prefs/plugin.
    local $ENV{LMS_PREFS_DIR} = Plugins::YouTubeMusic::Utils::prefs_dir();

    my @cmd = ('python3', $script, $method, $body_str, $cookie);

    my $cv = AnyEvent::Util::run_cmd(
        \@cmd,
        '<',  '/dev/null',
        '>',  \my $out,
        '2>', \my $err,
    );

    $cv->cb(sub {
        if ($err) {
            $log->warn("ytm_api.py stderr: $err") if length($err) > 0;
        }

        if (!$out || !length($out)) {
            $log->error("ytm_api.py returned empty output for $method");
            $cb->({ error => 'empty response from API script' });
            return;
        }

        my $result = eval { from_json($out) };
        if ($@) {
            $log->error("JSON parse error from ytm_api.py: $@");
            $log->error("Raw output (200): " . substr($out, 0, 200));
            $cb->({ error => "JSON parse error: $@" });
            return;
        }

        if ($result->{error}) {
            $log->error("ytm_api.py returned error: $result->{error}");
            $cb->({ error => $result->{error} });
            return;
        }

        $log->info("API $method succeeded, response size: " . length($out) . " bytes");
        $cb->($result);
    });
}

1;
