#!/usr/bin/perl
use strict;
use warnings;
use Math::Random;
use Time::HiRes qw( usleep );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Prototypes
sub red_alert();
sub red_flash();

# Effects states
my %EFFECTS = (
	'RED_ALERT' => \&red_alert,
	'RED_FLASH' => \&red_flash,
);

# User config
my $COLOR_TIMEOUT  = 30;
my $COLOR_TIME_MIN = int($COLOR_TIMEOUT / 2);
my %COLOR_VAR      = (
	'PLAY'      => 0.50,
	'PLAY_HIGH' => 0.50,
	'PAUSE'     => 0.65,
	'MOTION'    => 0.15,
);
my %DIM            = (
	'OFF'    => [
		# Handled by rope.pl
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
my $TEMP_DIR     = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR     = $TEMP_DIR . 'plexMonitor/';
my $OUTPUT_FILE  = $DATA_DIR . 'LED';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = 60;

# Reset the push timeout if the color timeout is longer
if ($PUSH_TIMEOUT < $COLOR_TIMEOUT) {
	$PUSH_TIMEOUT = $COLOR_TIMEOUT;
}

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Command-line arguments
my ($DELAY) = @ARGV;
if (!$DELAY) {
	$DELAY = $PULL_TIMEOUT / 2;
	if ($DELAY > $COLOR_TIMEOUT / 2) {
		$DELAY = $COLOR_TIMEOUT / 2;
	}
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
foreach my $key (keys(%EFFECTS)) {
	$VALID{$key} = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# State
my $state       = 'OFF';
my $stateLast   = $state;
my %exists      = ();
my %existsLast  = %exists;
my $pushLast    = 0;
my $pullLast    = time();
my @COLOR       = ();
my $colorChange = time();

# Always force lights out at launch
DMX::dim({ 'channel' => 13, 'value' => 0, 'time' => 0 });
DMX::dim({ 'channel' => 14, 'value' => 0, 'time' => 0 });
DMX::dim({ 'channel' => 15, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# Record the last state/exists data for diffs/resets
	$stateLast  = $state;
	%existsLast = %exists;

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

	# Special handling for effects states
	if (defined($EFFECTS{$newState})) {

		# Dispatch the handler
		$EFFECTS{$newState}->();

		# Force an update back to the original state
		$newState    = $stateLast;
		%exists      = %existsLast;
		@COLOR       = ();
		$colorChange = time() + $COLOR_TIME_MIN;
		$forceUpdate = 1;
	}

	# Calculate the new state
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
			$color = int($color);
			if ($color < 0) {
				$color = 0;
			} elsif ($color > 255) {
				$color = 255;
			}
			push(@COLOR, { 'channel' => $data->{'channel'}, 'value' => $color, 'time' => $time });
		}

		# Update
		$forceUpdate = 1;
		$colorChange = time();
		if ($DEBUG) {
			print STDERR "New color\n";
		}
	}

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
		$forceUpdate = 1;

		# Reset the color change sequence, so we always spend 1 cycle at white
		@COLOR       = ();
		$colorChange = time() + $COLOR_TIME_MIN;

		# Debug
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
	}

	# Update the lighting
	if ($forceUpdate) {

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
	}
}

# ======================================
# Effects routines
# These are blocking, so be careful
# ======================================
sub red_alert() {
	my $ramp  = 500;
	my @sound = ('afplay', '/mnt/media/Sounds/DMX/Red Alert.mp3');
	my $sleep = $ramp;

	my @other = ();
	push(@other, { 'channel' => 13, 'value' => 0, 'time' => 0 });
	push(@other, { 'channel' => 15, 'value' => 0, 'time' => 0 });
	foreach my $data (@other) {
		DMX::dim($data);
	}

	my %high = ('channel' => 14, 'value' => 255, 'time' => $ramp);
	my %low = %high;
	$low{'value'} = 64;

	DMX::dim(\%high);
	system(@sound);
	DMX::dim(\%low);
	usleep($sleep * 1000);

	DMX::dim(\%high);
	system(@sound);
	DMX::dim(\%low);
	usleep($sleep * 1000);

	DMX::dim(\%high);
	system(@sound);
	DMX::dim(\%low);
	usleep($sleep * 1000);
}

sub red_flash() {

}
