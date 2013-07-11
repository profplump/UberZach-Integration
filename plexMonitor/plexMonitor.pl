#!/usr/bin/perl
use strict;
use warnings;
use LWP::Simple;
use File::Basename;
use Time::HiRes qw( sleep );
use File::Temp qw( tempfile );

# Prototypes
sub xbmcHTTP($);

# App config
my $TEMP_DIR = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR = $TEMP_DIR . '/plexMonitor';

# xbmcHTTP commands
my %CMDS = (
	'PLAYING' => 'GetCurrentlyPlaying',
	'GUI'     => 'GetGuiStatus'
);

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
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

# Mode
my $MODE = 'PLAYING';
if (basename($0) =~ /GUI/i) {
	$MODE = 'GUI';
}

# Add the data directory as needed
if (!-d $DATA_DIR) {
	mkdir($DATA_DIR);
}

# Build our file name
my $OUT_FILE = $DATA_DIR . '/' . $MODE;

# Loop forever (unless no delay is set)
my $data     = '';
my $dataLast = '';
do {

	# Run the monitor command
	my $changed = 0;
	$dataLast = $data;
	$data     = xbmcHTTP($CMDS{$MODE});

	# Compare this data set to the last
	if ($data ne $dataLast) {
		$changed = 1;
		if ($DEBUG) {
			print STDERR "Change detected in data:\n" . $data . "\n";
		}
	}

	# Ensure the output file exists
	if (!-r $OUT_FILE) {
		$changed = 1;
	}

	# If anything changed, save the data to disk
	if ($changed) {
		my ($fh, $tmp) = tempfile($OUT_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $data;
		close($fh);
		rename($tmp, $OUT_FILE);
	}

	# Delay and loop
	sleep($DELAY);
} until ($DELAY == 0);

# Exit cleanly
exit(0);

sub xbmcHTTP($) {
	my ($cmd) = @_;
	my $data = get('http://localhost:3000/xbmcCmds/xbmcHttp?command=' . $cmd);
	if (!defined($data)) {
		$data = '';
	}
	return $data;
}
