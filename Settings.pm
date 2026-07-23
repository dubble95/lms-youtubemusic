package Plugins::YouTubeMusic::Settings;

use strict;
use base qw(Slim::Web::Settings);

use File::Spec::Functions qw(catfile);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use AnyEvent::Util;
use Plugins::YouTubeMusic::Utils;

my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');
my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');

sub name { return 'PLUGIN_YOUTUBEMUSIC' }
sub page { return 'plugins/YouTubeMusic/settings/basic.html' }
sub prefs { return ($prefs, qw(cookie)) }

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    # When cookie is saved via form POST, normalize it. The textarea accepts
    # both a raw "Cookie:" header (from DevTools) and a pasted Netscape
    # cookies.txt blob (from the "Get cookies.txt LOCALLY" browser extension).
    if ($params->{saveSettings} && defined $params->{pref_cookie}) {
        my $input = $params->{pref_cookie};
        $input =~ s/\r//g;
        $input =~ s/^\s+|\s+$//g;

        if (length($input) > 50) {
            # Preserve the raw input verbatim — it may be a Netscape cookies.txt
            # whose secure/expiry/domain attributes matter for yt-dlp. Store it
            # in its own pref so ProtocolHandler can write it to disk as-is.
            $prefs->set('cookie_raw', $input);

            # Also derive a normalized Cookie header for the ytmusicapi helpers
            # (which only understand a Cookie: header string).
            my $normalized = _normalize_cookie_input($input);
            $normalized =~ s/[\r\n]+/ /g;
            $normalized =~ s/^\s+|\s+$//g;

            if ($normalized && length($normalized) > 50) {
                # Persist the normalized header back so the textarea shows the
                # canonical form on reload.
                $params->{pref_cookie} = $normalized;
                $log->warn("Cookie normalized (" . length($normalized) . " chars) — regenerating ytmusicapi auth file");
                _regenerate_ytmusicapi_auth($normalized);
            } else {
                $log->error("Cookie normalization produced an empty result; keeping raw input");
            }
        } else {
            # Empty/short input means the user cleared the field.
            $prefs->set('cookie_raw', '');
        }
    }

    # Surface current auth state to the template so the UI can show
    # "Connected (Active Session)" vs "Cookie Expired" vs "Disconnected".
    my $current_cookie = $prefs->get('cookie');
    if ($current_cookie && length($current_cookie) > 50) {
        my $is_valid = _check_cookie_validity();
        $params->{cookie_configured} = ($is_valid == 1) ? 1 : 2;
    } else {
        $params->{cookie_configured} = 0;
    }

    $callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

sub _check_cookie_validity {
    my $plugin_info = Slim::Utils::PluginManager->allPlugins->{'YouTubeMusic'};
    my $script = $plugin_info && $plugin_info->{basedir}
        ? $plugin_info->{basedir} . '/ytm_check_auth.py'
        : '/usr/share/squeezeboxserver/Plugins/YouTubeMusic/ytm_check_auth.py';

    return 1 unless -f $script;

    my @cmd = ('python3', $script);
    my $cv = AnyEvent::Util::run_cmd(
        \@cmd,
        '<', '/dev/null',
        '>', \my $out,
        '2>', \my $err,
    );
    $cv->recv;
    if ($out && $out =~ /VALID/) {
        return 1;
    }
    return 0;
}

# Normalize either a Netscape cookies.txt blob or a raw Cookie header into a
# single canonical "name=value; ..." Cookie header string. Falls back to the
# raw input if the helper is unavailable.
sub _normalize_cookie_input {
    my $input = shift;

    my $plugin_info = Slim::Utils::PluginManager->allPlugins->{'YouTubeMusic'};
    my $script = $plugin_info && $plugin_info->{basedir}
        ? $plugin_info->{basedir} . '/ytm_netscape_to_cookie.py'
        : '/usr/share/squeezeboxserver/Plugins/YouTubeMusic/ytm_netscape_to_cookie.py';

    # Pass the input via stdin to avoid argv length / quoting pitfalls.
    my @cmd = ('python3', $script, '-');

    my $cv = AnyEvent::Util::run_cmd(
        \@cmd,
        '<', \$input,
        '>', \my $out,
        '2>', \my $err,
    );

    # run_cmd is async; we need the result synchronously here since the settings
    # handler must return the normalized value before rendering. Block on it.
    $cv->recv;

    if ($err && length($err)) {
        # The helper prints "OK:" on stderr on success; surface failures only.
        if ($err =~ /ERROR/) {
            $log->error("ytm_netscape_to_cookie.py: $err");
        } elsif ($err =~ /WARNING/) {
            $log->warn("ytm_netscape_to_cookie.py: $err");
        }
    }

    my $cookie = ($out // '');
    $cookie =~ s/[\r\n]+//g;
    $cookie =~ s/^\s+|\s+$//g;
    return $cookie;
}

# Call Python helper to regenerate ytmusicapi auth JSON from cookie string.
# The prefs directory is passed in so the helper no longer has to hardcode it.
sub _regenerate_ytmusicapi_auth {
    my $cookie = shift;

    my $plugin_info = Slim::Utils::PluginManager->allPlugins->{'YouTubeMusic'};
    my $script = $plugin_info && $plugin_info->{basedir}
        ? $plugin_info->{basedir} . '/ytm_auth_refresh.py'
        : '/usr/share/squeezeboxserver/Plugins/YouTubeMusic/ytm_auth_refresh.py';

    my @cmd = ('python3', $script, $cookie, Plugins::YouTubeMusic::Utils::prefs_dir());

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
