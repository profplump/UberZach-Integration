#!/usr/bin/perl
use strict;
use warnings;
use LWP::Simple;
use File::Basename;
use Time::HiRes qw( sleep );
use File::Temp qw( tempfile );
use URI::Escape;
use JSON;

# Prototypes
sub buildCmd($$);
sub xbmcJSON($$);
sub printHash($$);

# App config
my $BASE_URL = 'http://localhost:3005/jsonrpc?request=';
my $TEMP_DIR = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR = $TEMP_DIR . '/plexMonitor';

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}
my $JSON_DEBUG = 0;
if ($ENV{'JSON_DEBUG'}) {
	$JSON_DEBUG = 1;
}

# Command-line arguments
my ($DELAY) = @ARGV;
if (!$DELAY) {
	$DELAY = 0;
}

# Sanity check
if (!-d $TEMP_DIR) {
	die("Bad config\n");
}

# Add the data directory as needed
if (!-d $DATA_DIR) {
	mkdir($DATA_DIR);
}

# Build our output file name
my $OUT_FILE = $DATA_DIR . '/PLAYING';

# Loop forever (unless no delay is set)
my %data     = ();
my %dataLast = ();
do {

	# Only update the file on a change
	my $changed = 0;
	%dataLast = %data;
	%data     = (
		'playing'    => 0,
		'playerid'   => -1,
		'time'       => 0,
		'title'      => '',
		'season',    => '',
		'episode',   => '',
		'duration',  => '',
		'showtitle', => '',
		'thumbnail', => '',
		'file',      => '',
		'fanart',    => '',
		'album'      => '',
		'artist',    => '',
		'year',      => '',
		'type'       => '',
		'windowid'   => '',
		'window'     => '',
		'selection'  => '',
	);

	# See if anything is playing
	my $result = xbmcJSON('Player.GetActivePlayers', undef());
	if (defined($result) && exists($result->{'playerid'})) {
		$data{'playing'}  = 1;
		$data{'playerid'} = $result->{'playerid'} + 0;
	}

	# Get details about the playing item
	if ($data{'playing'}) {
		$result = xbmcJSON('Player.GetProperties', { 'playerid' => $data{'playerid'}, 'properties' => [ 'time', 'type' ] });
		if (defined($result)) {
			if (exists($result->{'time'})) {
				$data{'time'} = 0;
				if (exists($result->{'time'}->{'hours'})) {
					$data{'time'} += ($result->{'time'}->{'hours'} * 3600);
				}
				if (exists($result->{'time'}->{'minutes'})) {
					$data{'time'} += ($result->{'time'}->{'minutes'} * 60);
				}
				if (exists($result->{'time'}->{'seconds'})) {
					$data{'time'} += $result->{'time'}->{'seconds'};
				}
				if (exists($result->{'time'}->{'milliseconds'})) {
					$data{'time'} += ($result->{'time'}->{'milliseconds'} / 1000);
				}
			}
			if (exists($result->{'type'})) {
				$data{'type'} = $result->{'type'};
			}
		}

		$result = xbmcJSON(
			'Player.GetItem',
			{
				'playerid'   => $data{'playerid'},
				'properties' => [ 'title', 'season', 'episode', 'duration', 'showtitle', 'thumbnail', 'file', 'fanart', 'album', 'artist', 'year' ]
			}
		);
		if (defined($result) && exists($result->{'item'})) {
			foreach my $key ('title', 'season', 'episode', 'duration', 'showtitle', 'thumbnail', 'file', 'fanart', 'album', 'year') {
				if (exists($result->{'item'}->{$key})) {
					$data{$key} = $result->{'item'}->{$key};
				}
			}
			if (exists($result->{'item'}->{'artist'})) {
				if (ref($result->{'item'}->{'artist'}) eq 'ARRAY') {
					$data{'artist'} = join(', ', @{ $result->{'item'}->{'artist'} });
				} else {
					warn("Invalid artist array\n");
				}
			}
		}
	}

	# Get details about the GUI
	$result = xbmcJSON('GUI.GetProperties', { 'properties' => [ 'currentcontrol', 'currentwindow' ] });
	if (defined($result)) {
		if (exists($result->{'currentwindow'})) {
			if (exists($result->{'currentwindow'}->{'label'})) {
				$data{'window'} = $result->{'currentwindow'}->{'label'};
			}
			if (exists($result->{'currentwindow'}->{'id'})) {
				$data{'windowid'} = $result->{'currentwindow'}->{'id'};
			}
		}
		if (exists($result->{'currentcontrol'})) {
			if (exists($result->{'currentcontrol'}->{'label'})) {
				$data{'selection'} = $result->{'currentcontrol'}->{'label'};
			}
		}
	}

	# Compare this data set to the last
	foreach my $key (keys(%data)) {
		if (!exists($dataLast{$key}) || $data{$key} ne $dataLast{$key}) {
			$changed = 1;
			last;
		}
	}

	# Ensure the output file exists
	if (!-r $OUT_FILE) {
		$changed = 1;
	}

	# If anything changed, save the data to disk
	if ($changed) {
		my $str = '';
		foreach my $key (keys(%data)) {
			$str .= $key . ':' . $data{$key} . "\n";
		}
		if ($DEBUG) {
			print STDERR $str;
		}

		my ($fh, $tmp) = tempfile($OUT_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $str;
		close($fh);
		rename($tmp, $OUT_FILE);
	}

	# Delay and loop
	sleep($DELAY);
} until ($DELAY == 0);

# Exit cleanly
exit(0);

sub buildCmd($$) {
	my ($method, $params) = @_;
	if (!defined($method) || length($method) < 1) {
		warn('No method name provided');
		return undef();
	}

	# Init the command structure
	my %cmd = (
		'jsonrpc' => '2.0',
		'id'      => '1',
		'method'  => $method,
	);

	# Add parameters, if provided
	if (defined($params) && ref($params) eq 'HASH') {
		$cmd{'params'} = $params;
	}

	# Return as JSON
	return encode_json(\%cmd);
}

sub xbmcJSON($$) {
	my ($method, $params) = @_;
	my $cmd = buildCmd($method, $params);

	# Send the request
	if ($JSON_DEBUG) {
		print STDERR 'Sending command: ' . $cmd . "\n";
	}
	my $data = get($BASE_URL . uri_escape($cmd));
	if (!defined($data)) {
		if ($DEBUG) {
			print STDERR "No data returned from RPC call\n";
		}
		return undef();
	}

	# Parse into a perl data structure
	my $retval = decode_json($data);
	if (!defined($retval) || ref($retval) ne 'HASH') {
		print STDERR 'Invalid JSON: ' . $data . "\n";
		return undef();
	}

	# Reduce to the result section
	if (exists($retval->{'result'})) {
		if (ref($retval->{'result'}) eq 'HASH') {
			$retval = $retval->{'result'};
		} elsif (ref($retval->{'result'}) eq 'ARRAY') {
			$retval = @{ $retval->{'result'} }[0];
		}
	}

	# Return what we've got
	if ($JSON_DEBUG) {
		print "Result:\n";
		printHash($retval, "\t");
	}
	return $retval;
}

sub printHash($$) {
	my ($hash, $prefix) = @_;
	my $nextPrefix = $prefix . substr($prefix, 0, 1);

	if (!defined($hash)) {
		return;
	} elsif (ref($hash) ne 'HASH') {
		print STDERR 'Invalid hash: ' . $hash . "\n";
	} else {
		foreach my $key (keys(%{$hash})) {
			if (ref($hash->{$key}) eq 'HASH') {
				print STDERR $prefix . $key . ":\n";
				printHash($hash->{$key}, $nextPrefix);
			} elsif (ref($hash->{$key}) eq 'ARRAY') {
				print STDERR $prefix . $key . " => [\n";
				foreach my $element (@{ $hash->{$key} }) {
					if (ref($element) eq 'HASH') {
						printHash($element, $nextPrefix);
					} else {
						print STDERR $nextPrefix . $element . "\n";
					}
				}
				print STDERR $prefix . "]\n";
			} else {
				print STDERR $prefix . $key . ' => ' . $hash->{$key} . "\n";
			}
		}
	}
}
