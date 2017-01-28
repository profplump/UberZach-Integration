#!/usr/bin/perl
use strict;
use warnings;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# User config
my $PREHEAT_DELAY   = 2;
my $PREHEAT_TIMEOUT = $PREHEAT_DELAY + 60;
my $MOTION_TIMEOUT  = 300;
my $ENABLE_TIMEOUT  = 1800;
my %DIM             = (
	'OFF'     => [ { 'channel' => 20, 'value' => 0,   'time' => 0 }, ],
	'ON'      => [ { 'channel' => 20, 'value' => 255, 'time' => 0 }, ],
	'PREHEAT' => [ { 'channel' => 20, 'value' => 255, 'time' => 0 }, ],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'OIL';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $MAX_DELAY    = $PULL_TIMEOUT / 2;
my $MIN_DELAY    = 0.25;
my $DELAY        = $MAX_DELAY;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# State
my $state       = 'OFF';
my $stateLast   = $state;
my $masterState = 'OFF';
my %exists      = ();
my %mtime       = ();
my $pushLast    = 0;
my $pullLast    = time();
my $update      = 0;
my $lastPlay    = 0;

# Always force the heater into OFF at launch
$state = 'OFF';
DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# Loop forever
while (1) {

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, \%mtime, undef());

	# Avoid repeated calls to time()
	my $now = time();

	# Record only valid states
	if (defined($cmdState)) {
		$masterState = $cmdState;
		$pullLast    = $now;
	}

	# Die if we don't see regular updates
	if ($now - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Remember the last master PLAY mtime
	if ($masterState eq 'PLAY') {
		$lastPlay = $now;
	}

	# Reduce our minimum update rate to make timer-based modes more accurate
	my $elapsed = $now - $lastPlay;
	if ($elapsed && $elapsed < $PREHEAT_TIMEOUT) {
		$DELAY = $MIN_DELAY;
	} else {
		$DELAY = $MAX_DELAY;
	}

	# Overall enable state
	my $enable = 0;
	if ($exists{'OIL_ENABLE'} && $mtime{'OIL_ENABLE'} > $now - $ENABLE_TIMEOUT) {
		$enable = 1;
	} elsif ($exists{'LOCK'}) {
		$enable = 1;
	}

	# Calculate the new state
	$stateLast = $state;
	$state     = 'OFF';
	if ($enable) {
		if ($mtime{'MOTION_GARAGE'} > $now - $MOTION_TIMEOUT) {
			$state = 'ON';
		} elsif (($masterState eq 'PAUSE' || $masterState eq 'MOTION')
			&& $PREHEAT_TIMEOUT > $elapsed
			&& $PREHEAT_DELAY < $elapsed)
		{
			$state = 'PREHEAT';
		}
	}

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
