use strict;
use JSON::XS;
use LWP::UserAgent;
use Data::Dumper;

my $ua = LWP::UserAgent->new;
my $req = HTTP::Request->new(POST => 'https://music.youtube.com/youtubei/v1/browse?prettyPrint=false&key=AIzaSyB-pwPtDkxF6JQmA8qq9h1md60MyI5Q5iA');
$req->header('Content-Type' => 'application/json');
my $body = encode_json({
    context => {
        client => {
            clientName => 'WEB_REMIX',
            clientVersion => '1.20230828.01.00',
        }
    },
    browseId => 'FEmusic_home'
});
$req->content($body);

my $res = $ua->request($req);
if ($res->is_success) {
    print "Success!\n";
    my $json = decode_json($res->content);
    
    # Just run the first few lines of _parseInnerTube
    my $contents;
    if ($json->{contents} && $json->{contents}->{singleColumnBrowseResultsRenderer}) {
        my $tabs = $json->{contents}->{singleColumnBrowseResultsRenderer}->{tabs};
        if ($tabs && @$tabs) {
            $contents = $tabs->[0]->{tabRenderer}->{content}->{sectionListRenderer}->{contents};
        }
    }
    print "Contents found: ", scalar(@$contents) if $contents;
    
    my @items;
    for my $section (@$contents) {
        my $shelf = $section->{musicShelfRenderer} || $section->{musicCarouselShelfRenderer} || $section->{itemSectionRenderer};
        if ($section->{musicGridRenderer}) { $shelf = $section->{musicGridRenderer}; }
        next unless $shelf;
        my $shelfContents = $shelf->{contents};
        next unless $shelfContents;
        
        for my $item (@$shelfContents) {
            my $renderer = $item->{musicResponsiveListItemRenderer} 
                        || $item->{musicTwoColumnItemRenderer} 
                        || $item->{musicTrackRenderer}
                        || $item->{musicNavigationButtonRenderer};
            next unless $renderer;
            
            # just trying to extract title
            my $title;
            eval {
                if ($renderer->{flexColumns}) {
                    $title = $renderer->{flexColumns}->[0]->{musicResponsiveListItemFlexColumnRenderer}->{text}->{runs}->[0]->{text};
                } else {
                    $title = $renderer->{title}->{runs}->[0]->{text};
                }
            };
            if ($@) { print "Crash on title: $@\n"; }
            push @items, $title if $title;
        }
    }
    print "Found ", scalar(@items), " items.\n";
} else {
    print "Failed: ", $res->status_line, "\n";
}
