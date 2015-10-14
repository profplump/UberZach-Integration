#!/usr/bin/perl
use strict;
use warnings;
use POSIX;
use Math::Random;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# User config
my $COLOR_TIMEOUT  = 10;
my $COLOR_TIME_MIN = int($COLOR_TIMEOUT / 2);
my %COLOR_VAR      = (
	'PREMOTION'  => 0.75,
	'MOTION'     => 0.35,
	'POSTMOTION' => 0.75,
);
my $MOTION_TIMEOUT     = 30;
my $POSTMOTION_TIMEOUT = 60;
my %DIM                = (
	'OFF' =>         [
			{ 'channel' => 21, 'value' => 0,   'time' => 60000 },
			{ 'channel' => 22, 'value' => 0,   'time' => 60000 },
			{ 'channel' => 23, 'value' => 0,   'time' => 60000 },
	],
	'PREMOTION'  => [
			{ 'channel' => 21, 'value' => 5,   'time' => 2500 },
			{ 'channel' => 22, 'value' => 5,   'time' => 2500 },
			{ 'channel' => 23, 'value' => 5,   'time' => 2500 },
			],
	'MOTION'     => [
			{ 'channel' => 21, 'value' => 128,  'time' => 750 },
			{ 'channel' => 22, 'value' => 128,  'time' => 750 },
			{ 'channel' => 23, 'value' => 128,  'time' => 750 },
	],
	'POSTMOTION' => [
			{ 'channel' => 21, 'value' => 8,   'time' => $POSTMOTION_TIMEOUT * 1000 },
			{ 'channel' => 22, 'value' => 8,   'time' => $POSTMOTION_TIMEOUT * 1000 },
			{ 'channel' => 23, 'value' => 8,   'time' => $POSTMOTION_TIMEOUT * 1000 },
	],
	'BRIGHT'     => [
			{ 'channel' => 21, 'value' => 255,  'time' => 1000 },
			{ 'channel' => 22, 'value' => 255,  'time' => 1000 },
			{ 'channel' => 23, 'value' => 255,  'time' => 1000 },
	],
	'ERROR'      => [
			{ 'channel' => 21, 'value' => 112,  'time' => 100 },
			{ 'channel' => 22, 'value' => 255,  'time' => 100 },
			{ 'channel' => 23, 'value' => 112,  'time' => 100 },
	],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'GARAGE_LEDS';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Reset the timeouts if the color delay demands it
if ($PUSH_TIMEOUT < $COLOR_TIMEOUT) {
	$PUSH_TIMEOUT = $COLOR_TIMEOUT / 2;
}
if ($DELAY > $COLOR_TIMEOUT / 2) {
	$DELAY = $COLOR_TIMEOUT / 2;
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
my $lastMotion  = 0;
my @COLOR       = ();
my $colorChange = 0;

# Always force lights into ERROR at launch
$state = 'ERROR';
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

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'BRIGHT'}) {
		$state = 'BRIGHT';
	} elsif ($mtime{'MOTION_GARAGE'} > $now - $MOTION_TIMEOUT) {
		$state      = 'MOTION';
		$lastMotion = $now;
	} elsif ($masterState eq 'PLAY' || $masterState eq 'PAUSE' || $masterState eq 'MOTION') {
		if ($now > $lastMotion + $POSTMOTION_TIMEOUT) {
			$state = 'PREMOTION';
		} else {
			$state = 'POSTMOTION';
		}
	} else {
		$state = 'OFF';
	}

	# Color changes
	if ($COLOR_VAR{$state} && $now - $colorChange > $COLOR_TIMEOUT) {
		@COLOR = ();

		# Grab the default (white) data
		my $lums = 0;
		foreach my $data (@{ $DIM{$state} }) {
			$lums += $data->{'value'};
		}
		my $numChans = scalar(@{ $DIM{$state} });
		my $max      = $lums / $numChans;

		# Pick the change interval
		my $time = int((rand($COLOR_TIMEOUT - $COLOR_TIME_MIN) + $COLOR_TIME_MIN) * 1000);

		# Assign each channel
		my @vals = random_normal($numChans, $max, $max * $COLOR_VAR{$state});
		foreach my $data (@{ $DIM{$state} }) {
			my $color = pop(@vals);
			push(@COLOR, { 'channel' => $data->{'channel'}, 'value' => $color, 'time' => $time });
		}

		# Update
		$update      = 1;
		$colorChange = $now;
		if ($DEBUG) {
			print STDERR "New color\n";
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

		# Reset the color change sequence on any state change, so we always spend 1 cycle at white
		if ($stateLast ne $state) {
			if ($DEBUG) {
				print STDERR "Reset color sequence\n";
			}
			@COLOR       = ();
			$colorChange = $now + $COLOR_TIME_MIN;
		}

		# Select a data set (color or standard)
		my @data_set    = ();
		my $local_state = $state;
		if (scalar(@COLOR)) {
			@data_set = @COLOR;
			$local_state .= ' (Color)';
		} else {
			@data_set = @{ $DIM{$state} };
		}

		# Update
		DMX::applyDataset(\@data_set, $local_state, $OUTPUT_FILE);

		# Update the push time
		$pushLast = $now;

		# Clear the update flag
		$update = 0;
	}
}
