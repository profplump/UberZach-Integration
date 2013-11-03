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
	'OFF' => [ { 'channel' => 11, 'value' => 0,   'time' => 0 } ],
	'ON'  => [ { 'channel' => 11, 'value' => 255, 'time' => 0 } ],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'FAN';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# State
my $state     = 'OFF';
my $stateLast = $state;
my %exists    = ();
my %last      = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;

# Always force lights into OFF at launch
$state = 'OFF';
DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;
	%last = %exists;

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

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'FAN_CMD'}) {
		$state = 'ON';
	} else {
		$state = 'OFF';
	}

	# Speak when FAN_CMD changes
	if (exists($exists{'FAN_CMD'}) && exists($last{'FAN_CMD'}) && $exists{'FAN_CMD'} ne $last{'FAN_CMD'}) {
		DMX::say('Fan ' . $state);
	}

	# Force updates on a periodic basis
	if (!$update && time() - $pushLast > $PUSH_TIMEOUT) {
		if ($DEBUG) {
			print STDERR "Forcing periodic update\n";
		}
		$update = 1;
	}

	# Force updates on any state change
	if (!$update && $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		$update = 1;
	}

	# Update the fan
	if ($update) {

		# Update
		DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}
}
