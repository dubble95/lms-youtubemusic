package Plugins::YouTubeMusic::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::OPMLBased);
use Time::HiRes;
use POSIX qw(SIGTERM);
use File::Spec ();
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::YouTubeMusic::Auth;
use Plugins::YouTubeMusic::API;
use Plugins::YouTubeMusic::ProtocolHandler;
use Plugins::YouTubeMusic::PlaylistProtocolHandler;
use Plugins::YouTubeMusic::Radio;

my $log;
my $prefs;
my $PROXY_PID;

sub initPlugin {
    my $class = shift;

    # Register the log category — use -> (method) syntax like schmij97.
    $log = Slim::Utils::Log->addLogCategory({
        'category'     => 'plugin.youtubemusic',
        'defaultLevel' => 'WARN',
        'description'  => 'PLUGIN_YOUTUBEMUSIC',
    });

    # Fallback if addLogCategory returned undef or died
    $log ||= do {
        eval { Slim::Utils::Log->addLogCategory('plugin.youtubemusic') };
        Slim::Utils::Log->logger('plugin.youtubemusic');
    };

    $log->warn('YouTube Music plugin loading.');

    $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');
    $prefs->init({ proxy_port => 9876 });

    $class->_start_proxy();

    $class->SUPER::initPlugin(
        feed   => \&handleFeed,
        tag    => 'youtubemusic',
        menu   => 'apps',
        is_app => 1,
        weight => 10,
    );

    if ( main::WEBUI ) {
        require Plugins::YouTubeMusic::Settings;
        Plugins::YouTubeMusic::Settings->new();
    }

    $log->warn('YouTube Music plugin loaded.');

    # Start the endless-radio auto-queue (subscribes to playlist notifications).
    Plugins::YouTubeMusic::Radio->init();
}

sub shutdownPlugin {
    my $class = shift;
    if ($PROXY_PID) {
        $log->info("Stopping YouTube Music proxy (PID $PROXY_PID)");
        eval { kill SIGTERM, $PROXY_PID };
        waitpid($PROXY_PID, 0);
        $PROXY_PID = undef;
    }
}

# Start the Python proxy (ytmproxy.py) that handles:
#   - InnerTube API calls (search, browse, library) with cookies
#   - Stream resolution via yt-dlp → ffmpeg pipe (MP3 output)
sub _start_proxy {
    my $class = shift;
    my $port   = $prefs->get('proxy_port') || 9876;
    my $script = File::Spec->catfile($class->_pluginDataFor('basedir'), 'ytmproxy.py');

    unless (-f $script) {
        $log->error("Proxy script not found at $script");
        return;
    }

    my $python = _find_python();
    unless ($python) {
        $log->error("python3 not found in PATH");
        return;
    }

    $log->info("Starting YouTube Music proxy: $python $script --port $port");

    my $pid = fork();
    if (!defined $pid) {
        $log->error("fork() failed: $!");
        return;
    }

    if ($pid == 0) {
        exec($python, $script, '--port', $port, '--log-level', 'WARNING') or do {
            $log->error("exec failed: $!");
            exit 1;
        };
    }

    $PROXY_PID = $pid;
    $log->info("Proxy started (PID $pid)");
}

sub _find_python {
    for my $py (qw(python3 python)) {
        my $path = `which $py 2>/dev/null`; chomp $path;
        return $path if $path && -x $path;
    }
    return undef;
}


sub getDisplayName { 'PLUGIN_YOUTUBEMUSIC' }

sub handleFeed {
    my ($client, $cb, $args) = @_;
    
    my $items = [
        {
            name => 'Search',
            type => 'search',
            url  => \&handleSearch,
        },
        {
            name => 'Home',
            type => 'link',
            url  => \&handleBrowse,
            passthrough => [ { browseId => 'FEmusic_home' } ],
        },
        {
            name => 'Explore',
            type => 'link',
            url  => \&handleBrowse,
            passthrough => [ { browseId => 'FEmusic_explore' } ],
        },
        {
            name => 'Charts',
            type => 'link',
            url  => \&handleBrowse,
            passthrough => [ { browseId => 'FEmusic_charts' } ],
        },
        {
            name => 'New Releases',
            type => 'link',
            url  => \&handleBrowse,
            passthrough => [ { browseId => 'FEmusic_new_releases_albums' } ],
        },
        {
            name => 'Library',
            type => 'link',
            url  => \&handleBrowse,
            passthrough => [ { browseId => 'FEmusic_library_library' } ],
        },
    ];

    $cb->({ items => $items });
}

sub handleSearch {
    my ($client, $cb, $args, $params) = @_;
    
    my $query = $params->{search};
    return unless $query;
    
    Plugins::YouTubeMusic::API->search(sub {
        my $result = shift;
        
        if (ref($result) eq 'HASH' && $result->{error}) {
            $cb->({ items => [{ name => "Error: " . $result->{error}, type => 'text' }] });
            return;
        }

        my $items;
        eval {
            $items = _parseInnerTube($result);
        };
        if ($@) {
            $log->error("Error parsing search response: $@");
            $cb->({ items => [{ name => "Parsing Error", type => 'text' }] });
            return;
        }

        $cb->({ items => $items });
    }, $query);
}

sub handleBrowse {
    my ($client, $cb, $args, $params) = @_;
    
    my $browseId = $params->{browseId};
    $log->warn("handleBrowse called with browseId: $browseId");
    
    Plugins::YouTubeMusic::API->browse(sub {
        my $result = shift;
        
        if (ref($result) eq 'HASH' && $result->{error}) {
            $log->warn("handleBrowse API error: $result->{error}");
            $cb->({ items => [{ name => "Error: " . $result->{error}, type => 'text' }] });
            return;
        }

        my $items;
        eval {
            $items = _parseInnerTube($result);
        };
        if ($@) {
            $log->error("Error parsing browse response: $@");
            $cb->({ items => [{ name => "Parsing Error", type => 'text' }] });
            return;
        }

        $log->warn("handleBrowse returning " . scalar(@$items) . " items");

        if ($browseId && ref($items) eq 'ARRAY' && @$items) {
            my $play_url = "ytmplaylist://$browseId";
            unshift @$items, {
                name  => "▶ Play All",
                type  => 'audio',
                url   => $play_url,
                play  => $play_url,
            };
        }

        $cb->({ items => $items });
    }, $browseId);
}

sub _parseInnerTube {
    my $result = shift;
    my @items;

    # Extract the top-level contents array from various response structures
    my $contents;
    if (ref($result) eq 'ARRAY') {
        $contents = $result;
    } elsif ($result->{contents} && $result->{contents}->{singleColumnBrowseResultsRenderer}) {
        # Browse response (FEmusic_home etc)
        my $tabs = $result->{contents}->{singleColumnBrowseResultsRenderer}->{tabs};
        if ($tabs && @$tabs) {
            $contents = $tabs->[0]->{tabRenderer}->{content}->{sectionListRenderer}->{contents};
        }
    } elsif ($result->{contents} && $result->{contents}->{tabbedSearchResultsRenderer}) {
        # Search response
        my $tabs = $result->{contents}->{tabbedSearchResultsRenderer}->{tabs};
        if ($tabs && @$tabs) {
            $contents = $tabs->[0]->{tabRenderer}->{content}->{sectionListRenderer}->{contents};
        }
    } elsif ($result->{contents} && $result->{contents}->{sectionListRenderer}) {
        $contents = $result->{contents}->{sectionListRenderer}->{contents};
    } elsif ($result->{contents} && $result->{contents}->{twoColumnBrowseResultsRenderer}) {
        # Album/playlist detail page
        my $tcbr = $result->{contents}->{twoColumnBrowseResultsRenderer};
        # Tracks are in secondaryContents
        my $sec = $tcbr->{secondaryContents}->{sectionListRenderer}->{contents};
        $contents = $sec if $sec && @$sec;
        # If empty, try tabs
        if (!$contents) {
            my $tabs = $tcbr->{tabs};
            if ($tabs && @$tabs) {
                $contents = $tabs->[0]->{tabRenderer}->{content}->{sectionListRenderer}->{contents};
            }
        }
    }

    if (!$contents || !@$contents) {
        $log->warn("_parseInnerTube: no contents found in response");
        return [{ name => 'No content found', type => 'text' }];
    }

    for my $section (@$contents) {
        # Handle structured section list from ytmproxy.py ({ title => '...', items => [...] })
        if (ref($section) eq 'HASH' && $section->{items} && ref($section->{items}) eq 'ARRAY') {
            my $shelfTitle = $section->{title} || 'Section';
            push @items, { name => "--- $shelfTitle ---", type => 'text' };
            for my $item (@{$section->{items}}) {
                if (!ref($item) || ref($item) ne 'HASH') {
                    next;
                }
                if ($item->{type} && $item->{type} eq 'song' || $item->{videoId}) {
                    push @items, {
                        name  => $item->{title} . ($item->{subtitle} ? " (" . $item->{subtitle} . ")" : ""),
                        type  => 'audio',
                        url   => "ytmusic://" . $item->{videoId},
                        image => $item->{thumbnail},
                    };
                } elsif ($item->{type} && $item->{type} eq 'mood_category' || $item->{params}) {
                    push @items, {
                        name => $item->{title},
                        type => 'link',
                        url  => \&handleBrowse,
                        passthrough => [ { browseId => $item->{browseId}, params => $item->{params} } ],
                    };
                } elsif ($item->{browseId}) {
                    push @items, _playlist_item($item->{title}, $item->{subtitle}, $item->{browseId}, $item->{thumbnail});
                }
            }
            next;
        }
        # musicCardShelfRenderer: top search result card (e.g. "best match")
        if ($section->{musicCardShelfRenderer}) {
            my $card = $section->{musicCardShelfRenderer};
            my $title    = _getText($card->{title});
            my $subtitle = _getText($card->{subtitle});
            my $thumb    = _getThumb($card);

            my ($videoId, $browseId);

            # videoId from buttons
            if ($card->{buttons} && ref($card->{buttons}) eq 'ARRAY') {
                for my $btn (@{$card->{buttons}}) {
                    my $br  = $btn->{buttonRenderer} or next;
                    my $cmd = $br->{command} || $br->{navigationEndpoint};
                    if ($cmd && $cmd->{watchEndpoint} && $cmd->{watchEndpoint}->{videoId}) {
                        $videoId = $cmd->{watchEndpoint}->{videoId};
                        last;
                    }
                }
            }
            # fallback: onTap
            if (!$videoId && $card->{onTap}) {
                $videoId  = $card->{onTap}->{watchEndpoint}->{videoId};
                $browseId = $card->{onTap}->{browseEndpoint}->{browseId} unless $videoId;
            }

            if ($videoId) {
                push @items, { name => $title . ($subtitle ? " ($subtitle)" : ""), type => 'audio', url => "ytmusic://$videoId", image => $thumb };
            } elsif ($browseId) {
                push @items, _playlist_item($title, $subtitle, $browseId, $thumb);
                push @items, _playlist_play_item($title, $subtitle, $browseId, $thumb);
            }

            # Also parse shelf contents inside card (if any)
            for my $item (@{$card->{contents} || []}) {
                my $parsed = _parseListItem($item);
                push @items, $parsed if $parsed;
            }
            next;
        }

        # musicCarouselShelfRenderer: home page carousels
        if ($section->{musicCarouselShelfRenderer}) {
            my $shelf = $section->{musicCarouselShelfRenderer};
            my $header = $shelf->{header} || {};
            my $hdr_renderer = $header->{musicCarouselShelfBasicHeaderRenderer} || {};
            my $shelfTitle = _getText($hdr_renderer->{title} || $shelf->{title});
            if ($shelfTitle) {
                push @items, { name => "--- $shelfTitle ---", type => 'text' };
            }
            for my $item (@{$shelf->{contents} || []}) {
                my $parsed = _parseListItem($item);
                push @items, $parsed if $parsed;
            }
            next;
        }

        # musicShelfRenderer: search results grouped by type (Songs, Albums, etc.)
        if ($section->{musicShelfRenderer}) {
            my $shelf = $section->{musicShelfRenderer};
            my $shelfTitle = _getText($shelf->{title});
            if ($shelfTitle) {
                push @items, { name => "--- $shelfTitle ---", type => 'text' };
            }
            for my $item (@{$shelf->{contents} || []}) {
                my $parsed = _parseListItem($item);
                push @items, $parsed if $parsed;
            }
            next;
        }

        # musicGridRenderer: grid layout (new releases etc.)
        if ($section->{musicGridRenderer}) {
            my $shelf = $section->{musicGridRenderer};
            my $shelfTitle = _getText($shelf->{header}->{musicGridHeaderRenderer}->{title} || $shelf->{title});
            if ($shelfTitle) {
                push @items, { name => "--- $shelfTitle ---", type => 'text' };
            }
            for my $item (@{$shelf->{contents} || []}) {
                my $parsed = _parseListItem($item);
                push @items, $parsed if $parsed;
            }
            next;
        }

        # itemSectionRenderer: wraps individual items in search results
        if ($section->{itemSectionRenderer}) {
            my $isr = $section->{itemSectionRenderer};
            for my $item (@{$isr->{contents} || []}) {
                # Skip messageRenderer (e.g. "no results")
                next if $item->{messageRenderer};
                my $parsed = _parseListItem($item);
                push @items, $parsed if $parsed;
            }
            next;
        }

        # musicResponsiveHeaderRenderer: album/playlist header (skip, just metadata)
        next if $section->{musicResponsiveHeaderRenderer};
    }

    my $audio_count = scalar(grep { $_->{type} && $_->{type} eq 'audio' } @items);
    $log->info("_parseInnerTube: found " . scalar(@items) . " items ($audio_count audio)");

    return \@items;
}

# Parse a single shelf item - handles all renderer types
sub _parseListItem {
    my $item = shift;

    # musicTwoRowItemRenderer: home page carousel items (songs, playlists, albums, artists)
    if ($item->{musicTwoRowItemRenderer}) {
        my $r = $item->{musicTwoRowItemRenderer};
        my $title    = _getText($r->{title});
        my $subtitle = _getText($r->{subtitle});
        my $thumb    = _getThumb($r);

        my $nav      = $r->{navigationEndpoint} || {};
        my $videoId  = $nav->{watchEndpoint}->{videoId};
        my $browseId = $nav->{browseEndpoint}->{browseId};
        my $playlistId = $nav->{watchPlaylistEndpoint}->{playlistId}
                      || $nav->{watchEndpoint}->{playlistId};

        # Also check overlay for songs without direct videoId
        if (!$videoId && !$playlistId && $r->{overlay}) {
            my $play_ep = $r->{overlay}->{musicItemThumbnailOverlayRenderer}->{content}->{musicPlayButtonRenderer}->{playNavigationEndpoint} || {};
            $videoId = $play_ep->{watchEndpoint}->{videoId};
            $playlistId = $play_ep->{watchPlaylistEndpoint}->{playlistId}
                       || $play_ep->{watchEndpoint}->{playlistId};
        }

        if ($videoId) {
            return { name => $title . ($subtitle ? " ($subtitle)" : ""), type => 'audio', url => "ytmusic://$videoId", image => $thumb };
        }

        $browseId ||= "VL" . $playlistId if $playlistId;

        if ($browseId) {
            return _playlist_item($title, $subtitle, $browseId, $thumb);
        }
        return undef;
    }

    # musicResponsiveListItemRenderer: standard list item (songs, albums in search results)
    my $renderer = $item->{musicResponsiveListItemRenderer}
                || $item->{musicTwoColumnItemRenderer}
                || $item->{musicTrackRenderer}
                || $item->{musicNavigationButtonRenderer};
    return undef unless $renderer;

    my ($title, $subtitle, $thumb, $browseId, $videoId, $playlistId);

    if ($renderer->{flexColumns}) {
        $title    = _getText($renderer->{flexColumns}->[0]->{musicResponsiveListItemFlexColumnRenderer}->{text});
        $subtitle = _getText($renderer->{flexColumns}->[1]->{musicResponsiveListItemFlexColumnRenderer}->{text}) if $renderer->{flexColumns}->[1];
        $thumb    = _getThumb($renderer);

        $videoId  = _findVideoId($renderer);
        $playlistId = _findPlaylistId($renderer);

        if (!$videoId && !$playlistId) {
            my $nav = $renderer->{navigationEndpoint};
            $browseId = $nav->{browseEndpoint}->{browseId} if $nav && $nav->{browseEndpoint};
            if (!$browseId) {
                my $fc0_runs = $renderer->{flexColumns}->[0]->{musicResponsiveListItemFlexColumnRenderer}->{text}->{runs};
                if ($fc0_runs && @$fc0_runs) {
                    my $fc0_nav = $fc0_runs->[0]->{navigationEndpoint};
                    $browseId = $fc0_nav->{browseEndpoint}->{browseId} if $fc0_nav && $fc0_nav->{browseEndpoint};
                }
            }
        }
    } else {
        $title    = _getText($renderer->{title} || $renderer->{buttonText});
        $subtitle = _getText($renderer->{longBylineText} || $renderer->{shortBylineText});
        $thumb    = _getThumb($renderer);

        $videoId = _findVideoId($renderer);
        $playlistId = _findPlaylistId($renderer);
        if (!$videoId && !$playlistId) {
            my $nav = $renderer->{navigationEndpoint} || $renderer->{clickCommand};
            $browseId = $nav->{browseEndpoint}->{browseId} if $nav && $nav->{browseEndpoint};
            $videoId  ||= $renderer->{videoId};
        }
    }

    if ($videoId) {
        return { name => $title . ($subtitle ? " ($subtitle)" : ""), type => 'audio', url => "ytmusic://$videoId", image => $thumb };
    }

    $browseId ||= "VL" . $playlistId if $playlistId;

    if ($browseId) {
        return _playlist_play_item($title, $subtitle, $browseId, $thumb);
    }
    return undef;
}

# Find videoId from known locations in a renderer object
sub _findVideoId {
    my $renderer = shift;

    # 1. Direct navigationEndpoint watchEndpoint
    if ($renderer->{navigationEndpoint} && $renderer->{navigationEndpoint}->{watchEndpoint}) {
        my $vid = $renderer->{navigationEndpoint}->{watchEndpoint}->{videoId};
        return $vid if $vid;
    }

    # 2. Overlay play button
    for my $ov_key (qw(overlay thumbnailOverlay)) {
        if ($renderer->{$ov_key}) {
            my $ov   = $renderer->{$ov_key}->{musicItemThumbnailOverlayRenderer} or next;
            my $play = $ov->{content}->{musicPlayButtonRenderer} or next;
            my $ep   = $play->{playNavigationEndpoint} or next;
            my $vid  = $ep->{watchEndpoint}->{videoId};
            return $vid if $vid;
        }
    }

    # 3. flexColumns runs navigationEndpoint (title link on song items)
    if ($renderer->{flexColumns}) {
        for my $fc (@{$renderer->{flexColumns}}) {
            my $fcd = $fc->{musicResponsiveListItemFlexColumnRenderer} or next;
            my $runs = $fcd->{text}->{runs} or next;
            for my $run (@$runs) {
                my $ep = $run->{navigationEndpoint} or next;
                my $vid = $ep->{watchEndpoint}->{videoId};
                return $vid if $vid;
            }
        }
    }

    return undef;
}

# Find playlistId from known locations in a renderer object
sub _findPlaylistId {
    my $renderer = shift;

    # 1. Direct navigationEndpoint watchPlaylistEndpoint or watchEndpoint
    if ($renderer->{navigationEndpoint}) {
        my $ep = $renderer->{navigationEndpoint};
        my $pid = $ep->{watchPlaylistEndpoint}->{playlistId} || $ep->{watchEndpoint}->{playlistId};
        return $pid if $pid;
    }

    # 2. Direct clickCommand
    if ($renderer->{clickCommand}) {
        my $ep = $renderer->{clickCommand};
        my $pid = $ep->{watchPlaylistEndpoint}->{playlistId} || $ep->{watchEndpoint}->{playlistId};
        return $pid if $pid;
    }

    # 3. Overlay play button
    for my $ov_key (qw(overlay thumbnailOverlay)) {
        if ($renderer->{$ov_key}) {
            my $ov   = $renderer->{$ov_key}->{musicItemThumbnailOverlayRenderer} or next;
            my $play = $ov->{content}->{musicPlayButtonRenderer} or next;
            my $ep   = $play->{playNavigationEndpoint} or next;
            my $pid  = $ep->{watchPlaylistEndpoint}->{playlistId} || $ep->{watchEndpoint}->{playlistId};
            return $pid if $pid;
        }
    }

    # 4. flexColumns runs navigationEndpoint (title link)
    if ($renderer->{flexColumns}) {
        for my $fc (@{$renderer->{flexColumns}}) {
            my $fcd = $fc->{musicResponsiveListItemFlexColumnRenderer} or next;
            my $runs = $fcd->{text}->{runs} or next;
            for my $run (@$runs) {
                my $ep = $run->{navigationEndpoint} or next;
                my $pid = $ep->{watchPlaylistEndpoint}->{playlistId} || $ep->{watchEndpoint}->{playlistId};
                return $pid if $pid;
            }
        }
    }

    return undef;
}

# Build a single playlist/album browse item. Because OPMLBased + XMLBrowser
# will not synthesize a Play action for sub-menu items, we make the item
# itself playable: type 'audio' with url=play= the ytmplaylist:// URL.
# Tapping it queues the whole playlist via PlaylistProtocolHandler. The
# folder/browsing path is preserved as a separate outline item emitted by
# the caller when it wants both.
sub _playlist_item {
    my ($title, $subtitle, $browse_id, $thumb) = @_;
    my $play_url = "ytmplaylist://$browse_id";
    my $label    = $title . ($subtitle ? " ($subtitle)" : "");
    return {
        name        => $label,
        type        => 'playlist',
        url         => \&handleBrowse,
        passthrough => [{ browseId => $browse_id }],
        play        => $play_url,
        playall     => $play_url,
        hasitems    => 1,
        image       => $thumb,
    };
}

# A companion to _playlist_item: a dedicated Play entry (type 'audio') that
# Material Skin will render with a play button / context-menu Play.
sub _playlist_play_item {
    my ($title, $subtitle, $browse_id, $thumb) = @_;
    my $play_url = "ytmplaylist://$browse_id";
    my $label    = $title . ($subtitle ? " ($subtitle)" : "");
    return {
        name  => "\x{25B6} $label",
        type  => 'audio',
        url   => $play_url,
        play  => $play_url,
        image => $thumb,
    };
}

sub _getText {
    my $node = shift;
    return "" unless $node;
    if ($node->{runs}) {
        return join("", map { $_->{text} || '' } @{$node->{runs}});
    }
    return $node->{simpleText} || "";
}

sub _getThumb {
    my $r = shift;
    return "" unless $r;
    
    # 1. Try thumbnailRenderer
    if ($r->{thumbnailRenderer} && $r->{thumbnailRenderer}->{musicThumbnailRenderer} &&
        $r->{thumbnailRenderer}->{musicThumbnailRenderer}->{thumbnail} &&
        $r->{thumbnailRenderer}->{musicThumbnailRenderer}->{thumbnail}->{thumbnails}) {
        my $list = $r->{thumbnailRenderer}->{musicThumbnailRenderer}->{thumbnail}->{thumbnails};
        if (ref($list) eq 'ARRAY' && @$list) {
            return $list->[-1]->{url} || "";
        }
    }
    
    # 2. Try thumbnail
    if ($r->{thumbnail} && $r->{thumbnail}->{musicThumbnailRenderer} &&
        $r->{thumbnail}->{musicThumbnailRenderer}->{thumbnail} &&
        $r->{thumbnail}->{musicThumbnailRenderer}->{thumbnail}->{thumbnails}) {
        my $list = $r->{thumbnail}->{musicThumbnailRenderer}->{thumbnail}->{thumbnails};
        if (ref($list) eq 'ARRAY' && @$list) {
            return $list->[-1]->{url} || "";
        }
    }
    
    # 3. Try direct thumbnail.thumbnails
    if ($r->{thumbnail} && $r->{thumbnail}->{thumbnails}) {
        my $list = $r->{thumbnail}->{thumbnails};
        if (ref($list) eq 'ARRAY' && @$list) {
            return $list->[-1]->{url} || "";
        }
    }
    
    return "";
}

1;

