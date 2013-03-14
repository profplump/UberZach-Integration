#!/usr/bin/perl
use strict;
use warnings;
use Time::HiRes qw( usleep );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# User config
my $RELAY_DELAY  = 0.20;
my %DIM          = (
	'OFF'    => [
		{ 'channel' => 16, 'value' => 0,   'time' => 0 }
	],
	'TOGGLE' => [
		{ 'channel' => 16, 'value' => 255, 'time' => 0 }
	],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'GARAGE';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $DELAY        = 60;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);

# State
my $state     = 'OFF';
my $stateLast = $state;
my %exists    = ();
my $pushLast  = 0;
my $update    = 0;

# Always force lights out at launch
DMX::dim({ 'channel' => 16, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = 'OFF';

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, undef());
	if (defined($cmdState)) {
		$newState = $cmdState;
	}

	# Calculate the new state
	$stateLast = $state;
	if ($newState eq 'TOGGLE') {
		$state = 'TOGGLE';
	} else {
		$state = 'OFF';
	}

	# Force updates on any state change
	if ($state ne $stateLast) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		$update = 1;
	}

	# Update the fan
	if ($update) {

		# Toggle on
		$state = 'TOGGLE';
		DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

		# Wait
		usleep($RELAY_DELAY * 1000000);

		# Toggle off
		$state = 'OFF';
		DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}
}
