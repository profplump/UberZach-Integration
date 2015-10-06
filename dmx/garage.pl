#!/usr/bin/perl
use strict;
use warnings;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# User config
my $MOTION_TIMEOUT     = 30;
my $POSTMOTION_TIMEOUT = 60;
my %DIM                = (
	'OFF'        => [ { 'channel' => 17, 'value' => 0,   'time' => 60000 }, ],
	'PREMOTION'  => [ { 'channel' => 17, 'value' => 128, 'time' => 2500 }, ],
	'MOTION'     => [ { 'channel' => 17, 'value' => 255, 'time' => 750 }, ],
	'POSTMOTION' => [ { 'channel' => 17, 'value' => 128, 'time' => $POSTMOTION_TIMEOUT * 1000 }, ],
	'BRIGHT'     => [ { 'channel' => 17, 'value' => 255, 'time' => 1000 }, ],
	'ERROR'      => [ { 'channel' => 17, 'value' => 255, 'time' => 100 }, ],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'GARAGE';
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
my $state      = 'OFF';
my $stateLast  = $state;
my %exists     = ();
my %mtime      = ();
my $pushLast   = 0;
my $pullLast   = time();
my $update     = 0;
my $lastMotion = 0;

# Always force lights into ERROR at launch
$state = 'ERROR';
DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, \%mtime, undef());

	# Avoid repeated calls to time()
	my $now = time();

	# Record only valid states
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = $now;
	}

	# Die if we don't see regular updates
	if ($now - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'BRIGHT'}) {
		$newState = 'BRIGHT';
	} elsif ($mtime{'MOTION_GARAGE'} > $now - $MOTION_TIMEOUT) {
		$newState   = 'MOTION';
		$lastMotion = $now;
	} elsif ($newState eq 'PLAY' || $newState eq 'PAUSE' || $newState eq 'MOTION') {
		if ($now > $lastMotion + $POSTMOTION_TIMEOUT) {
			$newState = 'PREMOTION';
		} else {
			$newState = 'POSTMOTION';
		}
	} else {
		$newState = 'OFF';
	}
	$state = $newState;

	# Force updates on a periodic basis
	if (!$update && $now - $pushLast > $PUSH_TIMEOUT) {
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

	# Update the lighting
	if ($update) {

		# Update
		DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

		# Update the push time
		$pushLast = $now;

		# Clear the update flag
		$update = 0;
	}
}
