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
my $OIL_CHANNEL    = 31;
my $OIL_BRIGHTNESS = 0.10;
my %DIM         = (
	'OFF' => [
		{ 'channel' => 29, 'value' => 0, 'time' => 60000 },
		{ 'channel' => 30, 'value' => 0, 'time' => 60000 },
		{ 'channel' => 31, 'value' => 0, 'time' => 60000 },
	],
	'PLAY' => [
		{ 'channel' => 29, 'value' => 8, 'time' => 750 },
		{ 'channel' => 30, 'value' => 8, 'time' => 750 },
		{ 'channel' => 31, 'value' => 10,  'time' => 750 },
	],
	'PLAY_HIGH' => [
		{ 'channel' => 29, 'value' => 48, 'time' => 750 },
		{ 'channel' => 30, 'value' => 48, 'time' => 750 },
		{ 'channel' => 31, 'value' => 48, 'time' => 750 },
	],
	'PAUSE' => [
		{ 'channel' => 29, 'value' => 64, 'time' => 750 },
		{ 'channel' => 30, 'value' => 64, 'time' => 750 },
		{ 'channel' => 31, 'value' => 64, 'time' => 750 },
	],
	'MOTION' => [
		{ 'channel' => 29, 'value' => 96, 'time' => 750 },
		{ 'channel' => 30, 'value' => 96, 'time' => 750 },
		{ 'channel' => 31, 'value' => 96, 'time' => 750 },
	],
	'BRIGHT' => [
		{ 'channel' => 29, 'value' => 255, 'time' => 750 },
		{ 'channel' => 30, 'value' => 255, 'time' => 750 },
		{ 'channel' => 31, 'value' => 255, 'time' => 750 },
	],
	'ERROR' => [
		{ 'channel' => 29, 'value' => 144, 'time' => 100 },
		{ 'channel' => 30, 'value' => 255, 'time' => 100 },
		{ 'channel' => 31, 'value' => 144, 'time' => 100 },
	],
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'SHELF_HIGH';
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

# Construct a list of valid states
my %VALID = ();
foreach my $key (keys(%DIM)) {
	$VALID{$key} = 1;
}

# State
my $state       = 'OFF';
my $stateLast   = $state;
my %exists      = ();
my $pushLast    = 0;
my $pullLast    = time();
my $update      = 0;
my @COLOR       = ();
my $colorChange = 0;
my $enabled     = 0;
my $enabledLast = $enabled;

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
	my $cmdState = DMX::readState($DELAY, \%exists, undef(), \%VALID);

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

	# Skip processing when in RAVE or EFFECT mode
	if ($exists{'RAVE'} || $exists{'EFFECT'}) {
		if ($DEBUG) {
			print STDERR "Suspending normal operation while in RAVE mode\n";
		}
		$update = 1;
		next;
	}

	# Determine if OIL is enabled
	$enabledLast = $enabled;
	$enabled     = 0;
	if ($exists{'OIL'} =~ /\(Enabled\)/) {
		$enabled = 1;
	}

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'BRIGHT'}) {
		$newState = 'BRIGHT';
	} elsif ($exists{'LIGHTS'}) {
		if ($newState eq 'PLAY') {
			$newState = 'PLAY_HIGH';
		} else {
			$newState = 'MOTION';
		}
	}
	$state = $newState;

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

		# Assign each channel
		my @vals = random_normal($numChans, $max, $max * $COLOR_VAR{$state});
		foreach my $data (@{ $DIM{$state} }) {
			my $color = pop(@vals);
			push(@COLOR, { 'channel' => $data->{'channel'}, 'value' => $color, 'time' => 750 });
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

	# Force updates on any OIL enabled change
	if (!$update && $enabledLast != $enabled) {
		if ($DEBUG) {
			print STDERR 'Enabled change: ' . $enabledLast . ' => ' . $enabled . "\n";
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
		my $data        = $DIM{$state};
		my $local_state = $state;
		if (scalar(@COLOR)) {
			$data = \@COLOR;
			$local_state .= ' (Color)';
		}

		# Ensure it's safe to overwrite the data
		my @data_set = ();
		foreach my $set (@{ $data }) {
			my %tmp = %{ $set };
			push(@data_set, \%tmp);
		}

		# Override for $enabled -- similar brightness but only one channel
		if ($enabled) {
			my $sum = 0;
			my $ref = undef();
			foreach my $set (@data_set) {
				$sum += $set->{'value'};
				$set->{'value'} = 0;
				if ($set->{'channel'} == $OIL_CHANNEL) {
					$ref = $set;
				}
			}
			$ref->{'value'} = $sum * $OIL_BRIGHTNESS;
			$local_state .= ' [Oil]';
		}

		# Update
		DMX::applyDataset(\@data_set, $local_state, $OUTPUT_FILE);

		# Update the push time
		$pushLast = $now;

		# Clear the update flag
		$update = 0;
	}
}
