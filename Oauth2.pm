package Plugins::YouTubeMusic::Oauth2;

use strict;

use Data::Dumper;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use JSON::XS::VersionOneAndTwo;

my $log   = Slim::Utils::Log::logger('plugin.youtubemusic');
my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');
my $cache = Slim::Utils::Cache->new();

# YouTube on TV generic client ID and secret
my $CLIENT_ID = '861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com';
my $CLIENT_SECRET = 'a56GkKjG1oV3iF1BwK24D6Fp';

sub getToken {
    my $cb  = shift;
    my @params = @_;
    my $post = "client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET";
    
    my $code = $cache->get('ytm:device_code');
    
    if (defined $code) {
        $post .= "&code=$code&grant_type=http://oauth.net/grant_type/device/1.0";
    } else {
        my $refresh_token = $prefs->get('refresh_token');
        if ($refresh_token) {
            $post .= "&refresh_token=$refresh_token&grant_type=refresh_token";
        } else {
            $log->error("No device code or refresh token available.");
            $cb->(@params) if $cb;
            return;
        }
    }
    
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub { 
            my $response = shift;
            my $result = eval { from_json($response->content) };
                        
            if ($@) {
                $log->error(Data::Dump::dump($response)) unless main::DEBUGLOG && $log->is_debug;
                $log->error($@);
            } else {
                if ($result->{error}) {
                    $log->error("OAuth error: " . $result->{error} . " - " . ($result->{error_description} || ''));
                } else {
                    $cache->set("ytm:access_token", $result->{access_token}, $result->{expires_in} - 60);
                    $prefs->set('refresh_token', $result->{refresh_token}) if $result->{refresh_token};
                    
                    $cache->remove('ytm:user_code');
                    $cache->remove('ytm:verification_url');
                    $cache->remove('ytm:device_code');
                
                    $log->debug("Access token retrieved successfully");
                }
                $cb->(@params) if $cb;
            }
        },
        sub { 
            $log->error($_[1]);
            $cb->(@params) if $cb;
        },
        {
            timeout => 15,
        }
    );
    
    $http->post(
        "https://accounts.google.com/o/oauth2/token",
        'Content-Type' => 'application/x-www-form-urlencoded',
        $post,
    );
}


sub getCode {
    my $post = "client_id=$CLIENT_ID&scope=https://www.googleapis.com/auth/youtube";   
    
    $cache->remove('ytm:user_code');
    $cache->remove('ytm:verification_url');
    $cache->remove('ytm:device_code');
    $cache->remove('ytm:access_token');
                        
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        sub { 
            my $response = shift;
            my $result = eval { from_json($response->content) };
                        
            if ($@) {
                $log->error(Data::Dump::dump($response)) unless main::DEBUGLOG && $log->is_debug;
                $log->error($@);
            } else {
                $cache->set("ytm:device_code", $result->{device_code}, $result->{expires_in});
                $cache->set("ytm:verification_url", $result->{verification_url}, $result->{expires_in});
                $cache->set("ytm:user_code", $result->{user_code}, $result->{expires_in});
                                    
                $log->debug("Device code retrieved: " . $result->{user_code});
            }
        },
        sub { 
            $log->error($_[1]);
        },
        {
            timeout => 15,
        }
    );
    
    $http->post(
        "https://accounts.google.com/o/oauth2/device/code",
        'Content-Type' => 'application/x-www-form-urlencoded',
        $post,
    );
}

1;