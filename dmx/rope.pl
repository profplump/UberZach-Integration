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
	'OFF'    => [
		{ 'channel' => 0,  'value' => 0,   'time' => 60000 }
	],
	'PLAY'      => [
		{ 'channel' => 1,  'value' => 64,  'time' => 500   },
		{ 'channel' => 2,  'value' => 32,  'time' => 500   },
		{ 'channel' => 3,  'value' => 80,  'time' => 2500  },
		{ 'channel' => 5,  'value' => 64,  'time' => 500   },
		{ 'channel' => 6,  'value' => 36,  'time' => 500   },
		{ 'channel' => 7,  'value' => 32,  'time' => 500   },
		{ 'channel' => 8,  'value' => 16,  'time' => 500   },
		{ 'channel' => 9,  'value' => 16,  'time' => 500   },
	],
	'PLAY_HIGH' => [
		{ 'channel' => 1,  'value' => 255, 'time' => 500   },
		{ 'channel' => 2,  'value' => 128, 'time' => 500   },
		{ 'channel' => 3,  'value' => 192, 'time' => 1500  },
		{ 'channel' => 5,  'value' => 128, 'time' => 500   },
		{ 'channel' => 6,  'value' => 36,  'time' => 500   },
		{ 'channel' => 7,  'value' => 128, 'time' => 500   },
		{ 'channel' => 8,  'value' => 16,  'time' => 500   },
		{ 'channel' => 9,  'value' => 96,  'time' => 500   },
	],
	'PAUSE'     => [
		{ 'channel' => 1,  'value' => 255, 'time' => 1000  },
		{ 'channel' => 2,  'value' => 192, 'time' => 10000 },
		{ 'channel' => 3,  'value' => 192, 'time' => 5000  },
		{ 'channel' => 5,  'value' => 255, 'time' => 1000  },
		{ 'channel' => 6,  'value' => 104, 'time' => 6000, 'delay' => 3000 },
		{ 'channel' => 7,  'value' => 192, 'time' => 10000 },
		{ 'channel' => 8,  'value' => 96,  'time' => 6000, 'delay' => 6000 },
		{ 'channel' => 9,  'value' => 96,  'time' => 6000, 'delay' => 3000 },
	],
	'MOTION'    => [
		{ 'channel' => 1,  'value' => 255, 'time' => 1000  },
		{ 'channel' => 2,  'value' => 192, 'time' => 1000  },
		{ 'channel' => 3,  'value' => 192, 'time' => 1000  },
		{ 'channel' => 5,  'value' => 192, 'time' => 1000  },
		{ 'channel' => 6,  'value' => 104, 'time' => 1000  },
		{ 'channel' => 7,  'value' => 192, 'time' => 1000  },
		{ 'channel' => 8,  'value' => 96,  'time' => 2000  },
		{ 'channel' => 9,  'value' => 96,  'time' => 1500  },
	],
);

# App config
my $TEMP_DIR     = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR     = $TEMP_DIR . 'plexMonitor/';
my $OUTPUT_FILE  = $DATA_DIR . 'ROPE';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Command-line arguments
my ($DELAY) = @ARGV;
if (!$DELAY) {
	$DELAY = $PULL_TIMEOUT / 2;
}

# Sanity check
if (!-d $DATA_DIR) {
	die("Bad config\n");
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
my $pushLast  = 0;
my $pullLast  = time();

# Always force lights out at launch
DMX::dim({ 'channel' => 0, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# Set anywhere to force an update this cycle
	my $forceUpdate = 0;

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, \%VALID);
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
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

	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		$forceUpdate = 1;
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Force updates on any state change
	if ($stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		$forceUpdate = 1;
	}

	# Update the lighting
	if ($forceUpdate) {
		# Update
		DMX::applyDataset($DIM{$state}, $state, $OUTPUT_FILE);

		# Update the push time
		$pushLast = time();
	}
}
