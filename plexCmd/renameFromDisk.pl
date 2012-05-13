#!/usr/bin/perl
use strict;
use warnings;

# Includes
use URI::Escape;
use XML::Simple;
use LWP::Simple;
use File::Basename;
use HTTP::Request::Common;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Parameters
my ($host, $user, $pass, $section, $series) = @ARGV;
if (!$host || !$user || !$pass || (!$section && !$series)) {
	die('Usage: ' . basename($0) . ' host[:port] user passwd section_number [series_metadata_number]');
}

# Globals
if (!($host =~ /\:\d+$/)) {
	$host .= ':32400';
}
my $baseURL = 'http://' . $host;
my $auth    = 'X-Plex-User=' . $user . '&X-Plex-Pass=' . $pass;
my $xml     = new XML::Simple;

my @shows = ();
if ($series) {

	# Fetch just the provided show
	print STDERR 'Fetching show ' . $series . "\n";
	@shows = ('/library/metadata/' . $series . '/children');
} else {

	# Fetch the list of all shows in the section
	print STDERR "Fetching shows...\n";
	{
		my $content = get($baseURL . '/library/sections/' . $section . '/all/?' . $auth);
		if ($DEBUG) {
			print STDERR $baseURL . '/library/sections/' . $section . '/all/?' . $auth . "\n";
		}
		if (!$content) {
			die(basename($0) . ': Unable to fetch data for section: ' . $section . "\n");
		}

		# Find all TV shows in the section
		{
			my $tree = $xml->XMLin($content);
			@shows = keys(%{ $tree->{'Directory'} });
		}
	}
	print STDERR 'Found ' . scalar(@shows) . " shows\n";
}

# Fetch the list of all seasons in each show
my @seasons = ();
print STDERR "Fetching seasons...\n";
foreach my $show (@shows) {
	my $content = get($baseURL . $show . '?' . $auth);
	if ($DEBUG) {
		print STDERR $baseURL . $show . '?' . $auth . "\n";
	}
	if (!$content) {
		warn(basename($0) . ': Could not fetch seasons for show: ' . $show . "\n");
		next;
	}

	# Find all seasons in the show
	{
		my $tree = $xml->XMLin($content);

		# XML::Simple retuns different structure depending on the number of same-named child elements
		if ($tree->{'Directory'}->{'key'}) {
			push(@seasons, $tree->{'Directory'}->{'key'});
		} else {
			push(@seasons, keys(%{ $tree->{'Directory'} }));
		}
	}
}
print STDERR 'Found ' . scalar(@seasons) . " seasons\n";

# Forget the list of shows
undef(@shows);

# Fetch the list of all episodes in each season
my @episodes = ();
print STDERR "Fetching episodes...\n";
foreach my $season (@seasons) {
	my $content = get($baseURL . $season . '?' . $auth);
	if ($DEBUG) {
		print STDERR $baseURL . $season . '?' . $auth . "\n";
	}
	if (!$content) {
		warn(basename($0) . ': Could not fetch episodes for season: ' . $season . "\n");
		next;
	}

	# Find all episodes in the season
	{
		my $tree = $xml->XMLin($content);

		# XML::Simple retuns different structure depending on the number of same-named child elements
		if ($tree->{'Video'}->{'key'}) {
			push(@episodes, $tree->{'Video'}->{'key'});
		} else {
			push(@episodes, keys(%{ $tree->{'Video'} }));
		}
	}
}
print STDERR 'Found ' . scalar(@episodes) . " episodes\n";

# Forget the list of seasons
undef(@seasons);

# Fetch the metadata from each episode
print STDERR "Checking episodes...\n";
foreach my $episode (@episodes) {
	my $content = get($baseURL . $episode . '?' . $auth);
	if ($DEBUG) {
		print STDERR $baseURL . $episode . '?' . $auth . "\n";
	}
	if (!$content) {
		warn(basename($0) . ': Could not fetch metadata for episode: ' . $episode . "\n");
		next;
	}

	# Parse the metadata
	{
		my $tree    = $xml->XMLin($content);
		my $title   = $tree->{'Video'}->{'title'};
		my $summary = $tree->{'Video'}->{'summary'};
		my $file    = $tree->{'Video'}->{'Media'}->{'Part'}->{'file'};

		if (!$title) {
			warn('Invalid title for episode: ' . $episode . "\n");
			next;
		}
		if (!$file) {
			if (!$tree->{'Video'}->{'Media'}->{'key'}) {
				warn('No support for multi-file episodes: ' . $episode . "\n");
			} else {
				warn('Invalid file for episode: ' . $episode . "\n");
			}
			next;
		}

		# Rename if the file has a valid name but the episode does not
		$file = uri_unescape($file);
		$file = basename($file);
		$file =~ s/^\d+\s+\-\s*//;
		$file =~ s/S\d+E\d+\s+\-\s*//i;
		$file =~ s/\.\w{2,4}//;
		if (!$file || length($file) < 2 || $file =~ /NoName/i || $file =~ /Episode\s+\d+/i) {
			next;
		}
		if ($file =~ /\s+S\d+D\d+\-\d+$/) {
			print STDERR 'Skipping encoder-named file: ' . $file . "\n";
		}
		if ($title =~ /^Episode\s+\d+$/) {
			my $ua      = LWP::UserAgent->new();
			my $encoded = uri_escape($file);

			print STDERR 'Renaming ' . $episode . ' from "' . $title . '" to "' . $file . '"' . "\n";
			my $url = $baseURL . $episode . '?title=' . $encoded . '&titleSort=' . $encoded . '&title.locked=1&titleSort.locked=1&' . $auth;
			my $request = HTTP::Request->new('PUT' => $url);
			$ua->request($request);

			if (!$summary) {
				print STDERR "\tAlso setting summary\n";
				$url = $baseURL . $episode . '?title=' . $encoded . '&summary=' . $encoded . '&summary.locked=1&' . $auth;
				$request = HTTP::Request->new('PUT' => $url);
				$ua->request($request);
			}
		}
	}
}
