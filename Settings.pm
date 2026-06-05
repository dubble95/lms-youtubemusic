package Plugins::YouTubeMusic::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Plugins::YouTubeMusic::Oauth2;

my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');
my $cache = Slim::Utils::Cache->new();

sub name {
    return 'PLUGIN_YOUTUBEMUSIC';
}

sub page {
    return 'plugins/YouTubeMusic/settings/basic.html';
}

sub prefs {
    return ($prefs, qw(cookie refresh_token));
}

sub handler {
    my ($class, $client, $params, $callback, @args) = @_;

    if ($params->{get_code}) {
        Plugins::YouTubeMusic::Oauth2::getCode();
    }
    
    if ($params->{refresh}) {
        Plugins::YouTubeMusic::Oauth2::getToken();
    }
    
    if ($params->{clear_token}) {
        $cache->remove('ytm:access_token');
        $prefs->remove('refresh_token');
    }

    $params->{user_code} = $cache->get('ytm:user_code');
    $params->{authorize_link} = $cache->get('ytm:verification_url');
    $params->{access_token} = $cache->get('ytm:access_token');
    $params->{refresh_token} = $prefs->get('refresh_token');
    
    # If we have a device code but no access token, try to poll for it
    if ($cache->get('ytm:device_code') && !$cache->get('ytm:access_token')) {
        Plugins::YouTubeMusic::Oauth2::getToken();
    }

    $callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

1;
