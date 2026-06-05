package Plugins::YouTubeMusic::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::YouTubeMusic::Auth;
use Plugins::YouTubeMusic::API;
use Plugins::YouTubeMusic::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.youtubemusic',
    'defaultLevel' => 'INFO',
    'description'  => 'PLUGIN_YOUTUBEMUSIC',
});

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'youtubemusic',
        menu   => 'radios',
        is_app => 1,
        weight => 10,
    );

    if ( main::WEBUI ) {
        require Plugins::YouTubeMusic::Settings;
        Plugins::YouTubeMusic::Settings->new();
    }

    $log->info('YouTube Music plugin loaded.');
}

sub getDisplayName { 'PLUGIN_YOUTUBEMUSIC' }

sub handleFeed {
    my ($client, $cb, $args) = @_;
    
    my $items = [
        {
            name => 'Home',
            type => 'outline',
            url  => \&handleBrowse,
            passthrough => [ { browseId => 'FEmusic_home' } ],
        },
        {
            name => 'Explore',
            type => 'outline',
            url  => \&handleBrowse,
            passthrough => [ { browseId => 'FEmusic_explore' } ],
        },
        {
            name => 'Library',
            type => 'outline',
            url  => \&handleBrowse,
            passthrough => [ { browseId => 'FEmusic_library_library' } ],
        },
    ];
    
    $cb->($items);
}

sub handleBrowse {
    my ($client, $cb, $args, $params) = @_;
    
    my $browseId = $params->{browseId};
    
    Plugins::YouTubeMusic::API->browse(sub {
        my $result = shift;
        
        if ($result->{error}) {
            $cb->([{ name => "Error: " . $result->{error}, type => 'text' }]);
            return;
        }
        
        my $items = _parseInnerTube($result);
        
        $cb->($items);
    }, $browseId);
}

sub _parseInnerTube {
    my $result = shift;
    my @items;

    # Extract contents from response
    my $contents;
    if ($result->{contents} && $result->{contents}->{singleColumnBrowseResultsRenderer}) {
        my $tabs = $result->{contents}->{singleColumnBrowseResultsRenderer}->{tabs};
        if ($tabs && @$tabs) {
            $contents = $tabs->[0]->{tabRenderer}->{content}->{sectionListRenderer}->{contents};
        }
    } elsif ($result->{contents} && $result->{contents}->{sectionListRenderer}) {
        $contents = $result->{contents}->{sectionListRenderer}->{contents};
    }

    if (!$contents) {
        return [{ name => 'No content found', type => 'text' }];
    }

    for my $section (@$contents) {
        my $shelf = $section->{musicShelfRenderer} || $section->{musicCarouselShelfRenderer};
        next unless $shelf;

        # If it's a shelf, it might have a title
        my $shelfTitle = _getText($shelf->{header}->{musicHeaderRenderer}->{title} || $shelf->{title});
        if ($shelfTitle) {
            push @items, { name => "--- $shelfTitle ---", type => 'text' };
        }

        my $shelfContents = $shelf->{contents};
        next unless $shelfContents;

        for my $item (@$shelfContents) {
            my $renderer = $item->{musicResponsiveListItemRenderer} || $item->{musicTwoColumnItemRenderer};
            next unless $renderer;

            my $title = _getText($renderer->{flexColumns}->[0]->{musicResponsiveListItemFlexColumnRenderer}->{text});
            my $subtitle = _getText($renderer->{flexColumns}->[1]->{musicResponsiveListItemFlexColumnRenderer}->{text});
            
            my $thumb = $renderer->{thumbnail}->{musicThumbnailRenderer}->{thumbnail}->{thumbnails}->[0]->{url};
            
            my $navigation = $renderer->{navigationEndpoint};
            my $browseId = $navigation->{browseEndpoint}->{browseId};
            my $videoId = $navigation->{watchEndpoint}->{videoId};

            if ($videoId) {
                push @items, {
                    name => $title . ($subtitle ? " ($subtitle)" : ""),
                    type => 'audio',
                    url  => "ytmusic://$videoId",
                    image => $thumb,
                };
            } elsif ($browseId) {
                push @items, {
                    name => $title . ($subtitle ? " ($subtitle)" : ""),
                    type => 'outline',
                    url  => \&handleBrowse,
                    passthrough => [ { browseId => $browseId } ],
                    image => $thumb,
                };
            }
        }
    }

    return \@items;
}

sub _getText {
    my $node = shift;
    return "" unless $node;
    
    if ($node->{runs}) {
        return join("", map { $_->{text} } @{$node->{runs}});
    }
    
    return $node->{simpleText} || "";
}

1;
