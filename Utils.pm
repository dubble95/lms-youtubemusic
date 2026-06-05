package Plugins::YouTubeMusic::Utils;

use strict;
use feature 'state';
use warnings;

use File::Spec::Functions;
use Slim::Utils::Log;

my $log = Slim::Utils::Log::logger('plugin.youtubemusic');

sub yt_dlp_binary {
	my $bin;	
	my $os = Slim::Utils::OSDetect::details();
	
	if ($os->{'os'} eq 'Linux') {
		if ($os->{'osArch'} =~ /x86_64/) {
			$bin = "yt-dlp_linux";
		} elsif ($os->{'osArch'} =~ /aarch64/) {
			$bin = "yt-dlp_linux_aarch64";
		} elsif ($os->{'binArch'} =~ /arm/) {
			$bin = "yt-dlp_linux_armv7l";
		}
	}
	
	if ($os->{'os'} eq 'Darwin') {
		$bin = "yt-dlp_macos";
	}

	if ($os->{'os'} eq 'Windows') {
		if ($os->{'osArch'} =~ /8664/) {
			$bin = "yt-dlp.exe";
		} else {	
			$bin = "yt-dlp_x86.exe";
		}	
	}	
	
	if ($os->{'os'} eq 'FreeBSD' || ($os->{'os'} eq 'Unix' && $os->{'osName'} =~ /freebsd/)) {
		$bin = "yt-dlp_freebsd14";
	}
	
	$bin ||= 'yt-dlp';
	
	return $bin;
}

sub yt_dlp_bin {
	my $bin = shift || yt_dlp_binary();
	state $init;
	
	unless ($init) {
		my $base = catdir(Slim::Utils::PluginManager->allPlugins->{'YouTubeMusic'}->{'basedir'}, 'Bin');
		$init = 1;
	}	
	
	my ($exec) = grep { -e "$_/$bin" } Slim::Utils::Misc::getBinPaths();
	$exec = catdir($exec, $bin);
		
	if (!-x $exec) {
		$log->warn("$exec not executable - correcting");
		chmod (0555, $exec);
	}

	$bin = Slim::Utils::Misc::findbin($bin);
	$bin = Slim::Utils::OSDetect::getOS()->decodeExternalHelperPath($bin);
			
	return $bin;
}	

1;
