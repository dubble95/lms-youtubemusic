package Plugins::YouTubeMusic::Auth;

use strict;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.youtubemusic');

# Initialize defaults
$prefs->init({
    cookie => '',
});

sub getCookie {
    return $prefs->get('cookie');
}

1;
