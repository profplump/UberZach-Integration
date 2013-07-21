#!/usr/bin/perl
use strict;
use warnings;
use Time::HiRes qw( usleep sleep time );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# User config
my $RELAY_DELAY = 0.20;
my %DIM         = (
	'OFF'      => [ { 'channel' => 16, 'value' => 0,   'time' => 0 } ],
	'ACTIVATE' => [ { 'channel' => 16, 'value' => 255, 'time' => 0 } ],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'GARAGE';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
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
my $state     = 'OFF';
my $stateLast = $state;
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;

# Always force lights out at launch
DMX::dim({ 'channel' => 16, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = 'OFF';

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
	if ($newState eq 'ACTIVATE' || $exists{'GARAGE_CMD'}) {
		$state = 'ACTIVATE';
	} else {
		$state = 'OFF';
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

	# Special handling for toggle systems: only push if the state is "ACTIVATE"
	if ($update && $state ne 'ACTIVATE') {
		if ($DEBUG) {
			print STDERR 'Skipping non-activate state: ' . $state . "\n";
		}
		$update = 0;
	}

	# Update the relay
	if ($update) {

		# Annouce the command
		if ($exists{'GARAGE_CMD'}) {
			DMX::say('Garage door activated by ' . $exists{'GARAGE_CMD'});
		}

		# Toggle
		$state = 'ACTIVATE';
		DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);
		usleep($RELAY_DELAY * 1000000);
		$state = 'OFF';
		DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}
}
