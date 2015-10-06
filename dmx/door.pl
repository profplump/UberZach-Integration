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
my $STATE_SOCK   = 'DOOR';
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
	if ($newState eq 'ACTIVATE' || $exists{'DOOR_CMD'}) {
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

	# Do not operate when LOCKed
	if ($update && $exists{'LOCK'}) {
		DMX::say('Door locked');
		if ($exists{'DOOR_CMD'}) {
			DMX::say('Access denied to: ' . $exists{'DOOR_CMD'});
		}
		$update = 0;
	}

	# Update the relay
	if ($update) {

		# Annouce the command
		if ($exists{'DOOR_CMD'}) {
			DMX::say('Door activated by ' . $exists{'DOOR_CMD'});
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
