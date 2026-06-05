package Plugins::YouTubeMusic::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::YouTubeMusic::Oauth2;

my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');
my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');
my $cache = Slim::Utils::Cache->new();

use constant API_BASE_URL => 'https://music.youtube.com/youtubei/v1/';

sub browse {
    my ($class, $cb, $browse_id, $params) = @_;
    
    my $body = {
        browseId => $browse_id,
    };
    $body->{params} = $params if $params;
    
    _call('browse', $body, $cb);
}

sub search {
    my ($class, $cb, $query, $params) = @_;
    
    my $body = {
        query => $query,
    };
    $body->{params} = $params if $params;
    
    _call('search', $body, $cb);
}

sub _call {
    my ($method, $body, $cb) = @_;
    
    my $url = API_BASE_URL . $method . '?prettyPrint=false';
    
    # Add context to body
    $body->{context} = {
        client => {
            clientName => 'WEB_REMIX',
            clientVersion => '1.20230828.01.00',
        },
    };
    
    my $access_token = $cache->get('ytm:access_token');
    
    if (!$access_token && $prefs->get('refresh_token')) {
        $log->info("Access token expired or not found, refreshing...");
        Plugins::YouTubeMusic::Oauth2::getToken(sub {
            _call($method, $body, $cb);
        });
        return;
    }
    
    my @headers = (
        'Content-Type' => 'application/json',
        'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36',
    );
    
    push @headers, 'Authorization' => "Bearer $access_token" if $access_token;
    
    # Also support cookie-based auth if provided
    my $cookie = $prefs->get('cookie');
    push @headers, 'Cookie' => $cookie if $cookie;

    main::DEBUGLOG && $log->is_debug && $log->debug("Calling API: $url with body: " . to_json($body));

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $response = shift;
            my $result = eval { from_json($response->content) };

            if ($@) {
                $log->error("Error parsing JSON response from $url: $@");
                $log->error("Raw response: " . $response->content);
                $cb->({ error => 'JSON parse error' });
                return;
            }

            $cb->($result);
        },
        sub {
            my ($http, $error) = @_;
            $log->error("API call failed: $error");
            $cb->({ error => $error });
        },
        {
            timeout => 15,
        }
    )->post($url, @headers, to_json($body));
}

1;
