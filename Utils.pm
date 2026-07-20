package Plugins::YouTubeMusic::Utils;

use strict;
use feature 'state';
use warnings;

use File::Spec::Functions;
use Slim::Utils::Log;

my $log = Slim::Utils::Log::logger('plugin.youtubemusic');

# Return the LMS plugin prefs directory (the dir containing plugin/youtubemusic.prefs).
# The LMS prefs API exposes the absolute path neither via a method nor via
# $prefs->dir (that AUTOLOADs into pref values). Instead we resolve it from the
# namespace's internal 'file' attribute, then fall back to the global $::prefsdir
# (the --prefsdir flag, always set at boot), and finally to the historical
# Debian default. Using catdir keeps it portable across platforms.
sub prefs_dir {
    my $prefs = Slim::Utils::Prefs::preferences('plugin.youtubemusic');

    # 1. The Namespace object is a blessed hashref with its .prefs file path
    # stored under the 'file' key.
    if ($prefs && $prefs->{'file'}) {
        my ($vol, $dir, $file) = File::Spec::Functions::splitpath($prefs->{'file'});
        # splitpath returns the directory without the trailing filename portion;
        # on Unix $dir is the full parent dir. Make sure it exists.
        return $dir if $dir && -d $dir;
    }

    # 2. The global prefsdir flag + plugin suffix.
    if (defined $::prefsdir && length $::prefsdir) {
        my $dir = catdir($::prefsdir, 'plugin');
        return $dir if -d $dir;
    }

    # 3. Historical Debian default.
    return '/var/lib/squeezeboxserver/prefs/plugin';
}

sub yt_dlp_binary {
	my $bin;	
	my $os = Slim::Utils::OSDetect::details();
	
	if ($os->{'os'} eq 'Linux') {
		my $arch = $os->{'osArch'} || '';
		if ($arch =~ /x86_64/) {
			$bin = "yt-dlp_linux";
		} elsif ($arch =~ /aarch64/) {
			$bin = "yt-dlp_linux_aarch64";
		} elsif ($arch =~ /armv7/) {
			$bin = "yt-dlp_linux_armv7l";
		} elsif ($arch =~ /arm/) {
			$bin = "yt-dlp_linux_armv7l";
		} else {
			my $binArch = $os->{'binArch'} || '';
			if ($binArch =~ /arm/) {
				$bin = "yt-dlp_linux_armv7l";
			} else {
				$bin = "yt-dlp_linux";
			}
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
	my $bin_name = shift || yt_dlp_binary();
	
	# Priority 1: system yt-dlp (installed via pip, usually at /usr/local/bin/yt-dlp)
	# This is preferred: latest version, faster (Python vs compiled binary on armv7l)
	for my $sys_path (qw(/usr/local/bin/yt-dlp /usr/bin/yt-dlp)) {
		if (-x $sys_path) {
			$log->info("Using system yt-dlp: $sys_path");
			return $sys_path;
		}
	}
	
	# Priority 2: plugin Bin directory
	my $plugin_info = Slim::Utils::PluginManager->allPlugins->{'YouTubeMusic'};
	if ($plugin_info && $plugin_info->{'basedir'}) {
		my $plugin_bin = catdir($plugin_info->{'basedir'}, 'Bin', $bin_name);
		if (-e $plugin_bin) {
			unless (-x $plugin_bin) {
				$log->warn("$plugin_bin not executable - correcting");
				chmod(0755, $plugin_bin);
			}
			$log->info("Using yt-dlp from plugin Bin: $plugin_bin");
			return Slim::Utils::OSDetect::getOS()->decodeExternalHelperPath($plugin_bin);
		}
	}
	
	# Priority 3: LMS system bin paths
	my ($exec) = grep { -e catdir($_, $bin_name) } Slim::Utils::Misc::getBinPaths();
	if ($exec) {
		my $full_exec = catdir($exec, $bin_name);
		unless (-x $full_exec) {
			$log->warn("$full_exec not executable - correcting");
			chmod(0555, $full_exec);
		}
	}

	my $found = Slim::Utils::Misc::findbin($bin_name);
	if ($found) {
		$found = Slim::Utils::OSDetect::getOS()->decodeExternalHelperPath($found);
		return $found;
	}
	
	$log->warn("Could not find yt-dlp binary: $bin_name");
	return undef;
}	

1;
