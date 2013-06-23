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
	'Harry Potter 1' => {
		'file'   => 'Harry Potter/Harry Potter 1_ The Sorcerer\'s Stone.mp3',
		'part'   => '82481',
		'offset' => 100,
	},
	'Harry Potter 2' => {
		'file'   => 'Harry Potter/Harry Potter 2_ The Chamber of Secrets.mp3',
		'part'   => '82469',
		'offset' => 100,
	}
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'RIFF';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $PULL_TIMEOUT = 60;
my $DELAY        = $PULL_TIMEOUT / 2;

# Prototypes
sub runApplescript($);

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# State
my $RIFF     = undef();
my %exists   = ();
my $pullLast = time();

# Validate our riff files at launch
foreach my $riff (keys(%RIFFS)) {
	if ($RIFFS{$riff}{'file'} =~ /^\//) {
		$RIFFS{$riff}{'path'} = $RIFFS{$riff}{'file'};
	} else {
		$RIFFS{$riff}{'path'} = $RIFF_PATH . '/' . $RIFFS{$riff}{'file'};
	}

	if (!-r $RIFFS{$riff}{'path'}) {
		die('Invalid riff file: ' . $riff . ' => ' . $RIFFS{$riff}{'path'} . "\n");
	}
}

# Loop forever
while (1) {

	# If the color profile has changed, save the state to disk
	#if ($colorLast ne $color) {
	#	if ($DEBUG) {
	#		print STDERR 'New color profile: ' . $colorLast . ' => ' . $color . "\n";
	#	}
	#	my ($fh, $tmp) = tempfile($OUTPUT_FILE . '.XXXXXXXX', 'UNLINK' => 0);
	#	print $fh $color . "\n";
	#	close($fh);
	#	rename($tmp, $OUTPUT_FILE);
	#}

	# State is calculated; use newState to gather data
	my $newState = $state;

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

	# Launch riffs when the underlying media is active
	if (!$RIFF && $cmdState eq 'PLAY') {
		my %tmp = ();
		$tmp{'url'} = $exists{'PLAYING_URL'};
		$RIFF = \%tmp;
	}

	# Close riffs when the underlying media stops
	if ($RIFF && $exists{'PLAYING_URL'} ne $RIFF->{'url'}) {
		$RIFF = undef();
	}
}
