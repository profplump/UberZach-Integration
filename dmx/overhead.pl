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
	'OFF'       => [ { 'channel' => 4, 'value' => 0,   'time' => 60000 }, ],
	'PLAY'      => [ { 'channel' => 4, 'value' => 32,  'time' => 500 }, ],
	'PLAY_HIGH' => [ { 'channel' => 4, 'value' => 48,  'time' => 500 }, ],
	'PAUSE'     => [ { 'channel' => 4, 'value' => 96,  'time' => 6000, 'delay' => 9000 }, ],
	'MOTION'    => [ { 'channel' => 4, 'value' => 128, 'time' => 2500 }, ],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'OVERHEAD';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
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
my %last      = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;

# Always force lights out at launch
DMX::dim({ 'channel' => 4, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;
	%last = %exists;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, undef(), \%VALID);
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Skip processing when in RAVE or EFFECT mode
	if ($exists{'RAVE'} || $exists{'EFFECT'}) {
		if ($DEBUG) {
			print STDERR "Suspending normal operation while in RAVE mode\n";
		}
		$update = 1;
		next;
	}

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'LIGHTS'}) {
		if ($newState eq 'PLAY') {
			$newState = 'PLAY_HIGH';
		} elsif ($newState eq 'OFF') {
			$newState = 'MOTION';
		}
	} else {
		if ($newState eq 'PLAY_HIGH') {
			$newState = 'PLAY';
		}
	}
	$state = $newState;

	# Speak when LIGHTS changes
	if (exists($exists{'LIGHTS'}) && exists($last{'LIGHTS'}) && $exists{'LIGHTS'} ne $last{'LIGHTS'}) {
		if ($exists{'LIGHTS'}) {
			DMX::say('Lights up');
		} else {
			DMX::say('Lights down');
		}
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
