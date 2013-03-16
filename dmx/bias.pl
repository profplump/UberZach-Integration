#!/usr/bin/perl
use strict;
use warnings;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# User config
my %DIM = (
	'OFF'    => [ { 'channel' => 12, 'value' => 0,   'time' => 60000 }, ],
	'PLAY'   => [ { 'channel' => 12, 'value' => 255, 'time' => 0 } ],
	'PAUSE'  => [ { 'channel' => 12, 'value' => 0,   'time' => 0, 'delay' => 10000 } ],
	'MOTION' => [ { 'channel' => 12, 'value' => 0,   'time' => 0 } ],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'BIAS';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Construct a list of valid states
my %VALID = ();
foreach my $key (keys(%DIM)) {
	$VALID{$key} = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# State
my $state     = 'OFF';
my $stateLast = $state;
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;

# Always force lights out at launch
DMX::dim({ 'channel' => 12, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, \%VALID);
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Accept the new state directly
	$stateLast = $state;
	$state     = $newState;

	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		$update = 1;
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Force updates on any state change
	if ($stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		$update = 1;
	}

	# Update the lighting
	if ($update) {

		# Update
		DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}
}
