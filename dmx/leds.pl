#!/usr/bin/perl
use strict;
use warnings;
use POSIX;
use File::Touch;
use Math::Random;
use Time::HiRes qw( usleep );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Prototypes
sub red_alert();
sub rave();
sub rave_loop();

# Effects states
my %EFFECTS = (
	'RED_ALERT' => \&red_alert,
	'RAVE'      => \&rave,
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
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'LED';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $RAVE_FILE    = $DATA_DIR . 'RAVE';
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
foreach my $key (keys(%EFFECTS)) {
	$VALID{$key} = 1;
}
$VALID{'STOP'} = 1;

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
my $update      = 0;
my @COLOR       = ();
my $colorChange = time();
my $PID         = undef();
my $EFFECT      = undef();
my $PID_START   = 0;

# Always force lights out at launch
DMX::dim({ 'channel' => 13, 'value' => 0, 'time' => 0 });
DMX::dim({ 'channel' => 14, 'value' => 0, 'time' => 0 });
DMX::dim({ 'channel' => 15, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# Record the last state/exists data for diffs/resets
	$stateLast  = $state;
	%existsLast = %exists;

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Reduce the select delay when we're processing background effects
	# We don't want to hang waiting for event updates
	my $delay = $DELAY;
	if (defined($PID)) {
		$delay = 0.01;
	}

	# Wait for state updates
	my $cmdState = DMX::readState($delay, \%exists, \%VALID);
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Handle "STOP" commands
	if ($newState eq 'STOP') {
		if (defined($PID)) {
			if ($DEBUG) {
				print STDERR "Ending background processing\n";
			}
			kill(SIGTERM, $PID);
		}

		$newState    = $state;
		$update = 1;
	}

	# Reap zombie children
	if (defined($PID)) {
		my $kid = waitpid($PID, WNOHANG);
		if ($kid > 0) {
			if ($DEBUG) {
				print STDERR 'Reaped child: ' . $PID . "\n";
			}

			# Forget our local bypass state
			$PID       = undef();
			$EFFECT    = undef();
			$PID_START = 0;

			# Clear the RAVE flag for other daemons
			if (-e $RAVE_FILE) {
				unlink($RAVE_FILE);
			}

			# Reset to standard
			@COLOR       = ();
			$colorChange = time() + $COLOR_TIME_MIN;
			$update = 1;
		}
	}

	# Continue special processing
	if (defined($EFFECT)) {
		$EFFECT->();
		next;
	}

	# Special handling for effects states
	if (defined($EFFECTS{$newState})) {

		# Dispatch the handler
		# Optionally skip the rest of this loop
		if($EFFECTS{$newState}->()) {
			next;
		}

		# Force an update back to the original state
		$newState    = $stateLast;
		%exists      = %existsLast;
		@COLOR       = ();
		$colorChange = time() + $COLOR_TIME_MIN;
		$update = 1;
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
			push(@COLOR, { 'channel' => $data->{'channel'}, 'value' => $color, 'time' => $time });
		}

		# Update
		$update = 1;
		$colorChange = time();
		if ($DEBUG) {
			print STDERR "New color\n";
		}
	}

	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		$update = 1;
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
		$update = 1;

		# Reset the color change sequence, so we always spend 1 cycle at white
		@COLOR       = ();
		$colorChange = time() + $COLOR_TIME_MIN;
	}

	# Update the lighting
	if ($update) {

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

		# Clear the RAVE file, just in case
		if (-e $RAVE_FILE) {
			unlink($RAVE_FILE);
			die("Cleared orphan RAVE file\n");
		}
	}
}

# ======================================
# Effects routines
# These are blocking, so be careful
# ======================================
sub red_alert() {
	if ($DEBUG) {
		print STDERR "red_alert()\n";
	}

	my $ramp  = 450;
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

	# Follow through on the loop
	return 0;
}

sub rave() {
	if ($DEBUG) {
		print STDERR "rave()\n";
	}

	my @sound = ('afplay', '/mnt/media/Sounds/DMX/Rave.mp3');

	# Play the sound in a child (i.e. in the background)
	$PID = fork();
	if (defined($PID) && $PID == 0) {
	    exec(@sound)
		or die('Unable to play sound: ' . join(' ', @sound) . "\n");
	}

	# Setup our loop handler
	$EFFECT = \&rave_loop;

	# Record our start time
	$PID_START = time();

	# Initiate the RAVE state
	touch($RAVE_FILE);

	# Do not pass GO, do not collect $200
	return 1;
}

sub rave_loop() {
	if ($DEBUG) {
		print STDERR "rave_loop()\n";
	}

	my $max_dur  = 350;
	my $max_val  = 255;
	my %channels = (
		1  => 1,
		2  => 1,
		4  => 1,
		5  => 1,
		6  => 1,
		7  => 1,
		8  => 1,
		9  => 1,
		13 => 1,
		14 => 1,
		15 => 1,
	);

	# Random data for each channel
	my @data_set = ();
	foreach my $chan (keys(%channels)) {
		my $val = int(rand($max_val));
		my $dur = int(rand($max_dur));
		push(@data_set, { 'channel' => $chan, 'value' => $val, 'time' => $dur });
	}

	# Push the data set
	DMX::applyDataset(\@data_set, 'RAVE', $OUTPUT_FILE);
	$pushLast = time();

	# Wait just a bit, to prevent seizures
	usleep($max_dur * 1000);
}
