#!/usr/bin/perl
use strict;
use warnings;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# User config
my $MIN_OUT = 40;
my $MAX_OUT = 180;
my $MAX_DMX = 255;
my $STEPS   = 8;
my $EXP     = 2.375;
my %DIM     = (
	'OFF'    => [ { 'channel' => 64, 'value' => 0,   'time' => 0 } ],
	'ON'     => [ { 'channel' => 64, 'value' => 255, 'time' => 0 } ],
	'RAW'    => [ { 'channel' => 64, 'value' => 0,   'time' => 0 } ],
	'RANDOM' => [ { 'channel' => 64, 'value' => 0,   'time' => 100 } ],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'RUMBLE';
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
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;

# Always force rumble into OFF at launch
$state = 'OFF';
DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

# Sockets
# We don't actually subscribe for state, but the framework is handy
DMX::stateSocket($STATE_SOCK);

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, undef(), undef(), undef());
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Calculate the new state
	my $newValue = undef();
	$stateLast = $state;
	if ($newState eq 'OFF' || $newState eq 'ON') {
		$state = $newState;
	} elsif ($newState eq 'RANDOM' || $newState eq 'RANDOM_FULL') {
		$state    = 'RANDOM';
		$newValue = int(rand($STEPS) + 1);
	} elsif ($newState =~ /^RANDOM_(HIGH|MED|LOW|MIN)$/) {
		$state = 'RANDOM';
		my $parts = ceil($STEPS / 3);
		$newValue = int(rand($parts) + 1);
		if ($1 eq 'HIGH') {
			$newValue += 2 * $parts;
		} elsif ($1 eq 'MED') {
			$newValue += $parts;
		} elsif ($1 eq 'OFF') {
			if ($newValue < $parts) {
				$newValue = 0;
			} else {
				$newValue += $parts;
			}
		}
	} elsif ($newState =~ /^(LEVEL|RAW)_(\d{1,3})$/) {
		if ($1 eq 'LEVEL') {
			$state = 'RANDOM';
		} else {
			$state = 'RAW';
		}
		$newValue = $2;
	}

	# In RAW mode, set the output directly (but safely)
	if (defined($newValue) && $state eq 'RAW') {
		if ($newValue > $MAX_DMX) {
			$newValue = $MAX_DMX;
		}
		if ($newValue < $MIN_OUT) {
			$newValue = 0;
		}
		$DIM{$state}[0]->{'value'} = $newValue;
		$update = 1;
	}

	# In RANDOM mode, convert our level number into a DMX value
	if (defined($newValue) && $state eq 'RANDOM') {

		# Level 0 and 1 are the same -- OFF
		if ($newValue <= 1) {
			$newValue = 0;
		}
		if ($newValue > $STEPS) {
			$newValue = $STEPS;
		}

		if ($DEBUG) {
			print STDERR 'Random value: ' . $newValue . ' (' . int($newValue * 100 / $STEPS) . "%)\n";
		}

		# Always update in RANDOM mode
		$update = 1;

		my $value = int($newValue**$EXP) + $MIN_OUT;
		if ($value <= $MIN_OUT) {
			$value = 0;
		} elsif ($value > $MAX_OUT) {
			$value = $MAX_DMX;
		}
		$DIM{$state}[0]->{'value'} = $value;
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
		my $text = $state . '-' . $DIM{$state}[0]->{'value'};
		if (defined($newValue)) {
			$text .= ' (' . $newValue . ')';
		}
		DMX::applyDataset($DIM{$state}, $text, $OUTPUT_FILE);

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}
}
