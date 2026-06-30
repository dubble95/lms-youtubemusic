package Plugins::YouTubeMusic::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use AnyEvent::Util;

my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');
my $cache = Slim::Utils::Cache->new();
my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');

sub name { return 'PLUGIN_YOUTUBEMUSIC' }
sub page { return 'plugins/YouTubeMusic/settings/basic.html' }
sub prefs { return ($prefs, qw(cookie)) }

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    # When cookie is saved via form POST, auto-regenerate ytmusicapi auth file
    if ($params->{saveSettings} && $params->{pref_cookie}) {
        my $cookie = $params->{pref_cookie};
        $cookie =~ s/[\r\n]+/ /g;
        $cookie =~ s/^\s+|\s+$//g;

        if (length($cookie) > 50) {
            $log->warn("Cookie saved — regenerating ytmusicapi auth file");
            _regenerate_ytmusicapi_auth($cookie);
        }
    }

    $callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

# Call Python helper to regenerate ytmusicapi auth JSON from cookie string
sub _regenerate_ytmusicapi_auth {
    my $cookie = shift;

    my $plugin_info = Slim::Utils::PluginManager->allPlugins->{'YouTubeMusic'};
    my $script = $plugin_info && $plugin_info->{basedir}
        ? $plugin_info->{basedir} . '/ytm_auth_refresh.py'
        : '/usr/share/squeezeboxserver/Plugins/YouTubeMusic/ytm_auth_refresh.py';

    my @cmd = ('python3', $script, $cookie);

    my $cv = AnyEvent::Util::run_cmd(
        \@cmd,
        '<', '/dev/null',
        '>', \my $out,
        '2>', \my $err,
    );

    $cv->cb(sub {
        if ($err && length($err)) {
            $log->warn("ytm_auth_refresh.py stderr: $err");
        }
        if ($out && $out =~ /OK/) {
            $log->warn("ytmusicapi auth file regenerated successfully");
        } else {
            $log->error("ytm_auth_refresh.py failed: $out");
        }
    });
}

1;
