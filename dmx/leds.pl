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
my $COLOR_TIMEOUT  = 30;
my $COLOR_TIME_MIN = int($COLOR_TIMEOUT / 2);
my %COLOR_VAR      = (
	'PLAY'      => 0.55,
	'PLAY_HIGH' => 0.40,
	'PAUSE'     => 0.50,
	'MOTION'    => 0.15,
);
my %DIM            = (
	'OFF'    => [
		{ 'channel' => 13,  'value' => 0,   'time' => 60000 },
		{ 'channel' => 14,  'value' => 0,   'time' => 60000 },
		{ 'channel' => 15,  'value' => 0,   'time' => 60000 },
	],
	'PLAY'      => [
		{ 'channel' => 13, 'value' => 10,   'time' => 500  },
		{ 'channel' => 14, 'value' => 10,   'time' => 500  },
		{ 'channel' => 15, 'value' => 8,    'time' => 500  },
	],
	'PLAY_HIGH' => [
		{ 'channel' => 13, 'value' => 64,  'time' => 1000, 'delay' => 3000 },
		{ 'channel' => 14, 'value' => 64,  'time' => 1000, 'delay' => 1500 },
		{ 'channel' => 15, 'value' => 64,  'time' => 1000, 'delay' => 0    },
	],
	'PAUSE'     => [
		{ 'channel' => 13, 'value' => 96,  'time' => 3000, 'delay' => 3000 },
		{ 'channel' => 14, 'value' => 96,  'time' => 3000, 'delay' => 0    },
		{ 'channel' => 15, 'value' => 96,  'time' => 3000, 'delay' => 7000 },
	],
	'MOTION'    => [
		{ 'channel' => 13, 'value' => 144, 'time' => 1000  },
		{ 'channel' => 14, 'value' => 144, 'time' => 1000  },
		{ 'channel' => 15, 'value' => 144, 'time' => 1000  },
	],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'LED';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
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

# Construct a list of valid states
my %VALID = ();
foreach my $key (keys(%DIM)) {
	$VALID{$key} = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# State
my $state       = 'OFF';
my $stateLast   = $state;
my %exists      = ();
my $pushLast    = 0;
my $pullLast    = time();
my $update      = 0;
my @COLOR       = ();
my $colorChange = time();

# Always force lights out at launch
DMX::dim({ 'channel' => 13, 'value' => 0, 'time' => 0 });
DMX::dim({ 'channel' => 14, 'value' => 0, 'time' => 0 });
DMX::dim({ 'channel' => 15, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;

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
	
	# Skip processing when in RAVE mode
	if ($exists{'RAVE'}) {
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
		}
	} else {
		if ($newState eq 'PLAY_HIGH') {
			$newState = 'PLAY';
		}
	}
	$state = $newState;

	# Color changes
	if ($COLOR_VAR{$state} && time() - $colorChange > $COLOR_TIMEOUT) {
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
		$colorChange = time();
		if ($DEBUG) {
			print STDERR "New color\n";
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

		# Reset the color change sequence on any state change, so we always spend 1 cycle at white
		if ($stateLast ne $state) {
			if ($DEBUG) {
				print STDERR "Reset color sequence\n";
			}
			@COLOR       = ();
			$colorChange = time() + $COLOR_TIME_MIN;
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
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}
}
