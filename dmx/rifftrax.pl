#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw( tempfile );
use Time::HiRes qw( usleep sleep time );
use IPC::System::Simple qw( system capture );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;
use Audio;

# Config
my $RIFF_PATH = `~/bin/video/mediaPath` . '/iTunes/iTunes Music/RiffTrax';
my %RIFFS     = (
	'82481' => {
		'file'   => 'Harry Potter/Harry Potter 1_ The Sorcerer\'s Stone.mp3',
		'offset' => 100,
		'rate'   => 1.0,
	},
	'82469' => {
		'file'   => 'Harry Potter/Harry Potter 2_ The Chamber of Secrets.mp3',
		'offset' => 100,
		'rate'   => 1.0,
	}
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'RIFF';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $PULL_TIMEOUT = 60;
my $DELAY        = $PULL_TIMEOUT / 2;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# State
my $newState = 'OFF';
my $riff     = 0;
my $riffLast = $riff;
my $url      = '';
my $urlLast  = $url;
my %exists   = ();
my $pullLast = time();

# Validate the path for all our riff files at launch
foreach my $id (keys(%RIFFS)) {

	# Store the ID internally
	$RIFFS{$id}{'id'} = $id;

	# Construct an absolute path
	if ($RIFFS{$id}{'file'} =~ /^\//) {
		$RIFFS{$id}{'path'} = $RIFFS{$riff}{'file'};
	} else {
		$RIFFS{$id}{'path'} = $RIFF_PATH . '/' . $RIFFS{$id}{'file'};
	}

	# Ensure the path is valid
	if (!-r $RIFFS{$id}{'path'}) {
		die('Invalid riff file: ' . $id . ' => ' . $RIFFS{$id}{'path'} . "\n");
	}
}

# Loop forever
while (1) {

	# Save the last RIFF
	$riffLast = $riff;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, undef(), undef());
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Save the last URL, so we can find changes
	# Do not delete the last URL if no new one is provided
	if ($exists{'PLAYING_URL'}) {
		$urlLast = $url;
		$url     = $exists{'PLAYING_URL'};
	}

	# Update our state when the PLAYING_URL changes
	if ($url ne $urlLast) {

		# If a RIFF was active, clear it
		if ($riff) {
			if ($DEBUG) {
				print STDERR "RIFF cleared\n";
			}
			$riff = 0;
		}

		# Activate a new RIFF, if applicable
		if ($url =~ /\/library\/parts\/(\d+)\//) {
			if (exists($RIFFS{$1})) {
				if ($DEBUG) {
					print STDERR 'Matched RIFF: ' . $1 . ' => ' . $RIFFS{$riff}{'path'};
				}
				$riff = $1;
			}
		}
	}

	# If the RIFF has changed, save the state to disk
	if ($riff ne $riffLast) {
		my $new = '<none>';
		if ($riff) {
			$new = $RIFFS{$riff}{'id'};
		}
		my $old = $new;
		if ($riffLast) {
			$old = $RIFFS{$riffLast}{'id'};
		}

		if ($DEBUG) {
			print STDERR 'New RIFF: ' . $old . ' => ' . $new . "\n";
		}

		my ($fh, $tmp) = tempfile($OUTPUT_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $new . "\n";
		close($fh);
		rename($tmp, $OUTPUT_FILE);
	}
}
