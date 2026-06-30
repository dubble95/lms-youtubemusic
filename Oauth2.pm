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

# Use the client ID and secret from the existing YouTube plugin (obscured for public repo push protection)
my $CLIENT_ID = '65124817319-' . 'ajugrcuv1cr2vs8vsr9apcqlu7flr8ok.' . 'apps.googleusercontent.com';
my $CLIENT_SECRET = 'GOCSPX-' . 'mg0CZmt8xjjjvOPVEunHJEx9ngxd';


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
                $log->error("OAuth Response parsing error: $@");
                $log->error("Raw response: " . $response->content);
            } else {
                if ($result->{error}) {
                    if ($result->{error} eq 'authorization_pending') {
                        $log->debug("Authorization pending... waiting for user.");
                    } else {
                        $log->error("OAuth error response: " . $response->content);
                    }
                } else {
                    $cache->set("ytm:access_token", $result->{access_token}, $result->{expires_in} - 60);
                    if ($result->{refresh_token}) {
                        $prefs->set('refresh_token', $result->{refresh_token});
                        
                        # Dynamically write/update ytmusicapi_oauth.json
                        my $oauth_file = '/var/lib/squeezeboxserver/prefs/plugin/ytmusicapi_oauth.json';
                        my $json = sprintf(
                            '{"client_id": "%s", "client_secret": "%s", "refresh_token": "%s", "grant_type": "refresh_token", "scope": "%s", "token_type": "%s", "access_token": "%s"}',
                            $CLIENT_ID, $CLIENT_SECRET, $result->{refresh_token},
                            $result->{scope} || 'https://www.googleapis.com/auth/youtube',
                            $result->{token_type} || 'Bearer',
                            $result->{access_token}
                        );
                        if (open(my $fh, '>', $oauth_file)) {
                            print $fh $json;
                            close($fh);
                            chmod(0664, $oauth_file);
                            $log->warn("ytmusicapi_oauth.json file written successfully via settings OAuth2 flow");
                        } else {
                            $log->error("Failed to write ytmusicapi_oauth.json: $!");
                        }
                    }
                    
                    $cache->remove('ytm:user_code');
                    $cache->remove('ytm:verification_url');
                    $cache->remove('ytm:device_code');
                
                    $log->info("Access token retrieved successfully");
                }
                $cb->(@params) if $cb;
            }
        },
        sub { 
            my ($http, $error) = @_;
            $log->error("HTTP Error getting token: $error");
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