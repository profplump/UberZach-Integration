#!/usr/bin/perl
use strict;
use warnings;
use POSIX;
use File::Touch;
use File::Basename;
use Time::HiRes qw( usleep sleep time );
use IPC::System::Simple qw( system capture );
use Sys::Hostname;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;
use Audio;

# Effect Prototypes
sub red_alert($$$);
sub lsr_init($$$);
sub lsr_run($$$);
sub lsr_loop($$$);

# User config
my $MEDIA_PATH = `~/bin/video/mediaPath` . '/DMX';
my @CHANNELS   = (1, 2, 4, 5, 6, 7, 8, 9, 13, 14, 15);
my %EFFECTS    = ();
my %FILES      = ();

# Red Alert
$FILES{'RED_ALERT'} = 'DMX/Red Alert.mp3';
$EFFECTS{'RED_ALERT'} = { 'cmd' => \&red_alert };

# Light-switch rave
$EFFECTS{'LSR'} = { 'cmd' => \&lsr_init, 'next' => \&lsr_run, 'loop' => \&lsr_loop, 'done' => \&lsr_done };
$FILES{'LSR'} = 'DMX/Rave.mp3';

# Utility prototypes
sub loadFiles($);
sub ampWait($$$);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'RAVE_CMD';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $RAVE_FILE    = $DATA_DIR . 'RAVE';
my $EFFECT_FILE  = $DATA_DIR . 'EFFECT';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;
my $AMP_DELAY    = 6;
my $AMP_BOOTING  = 0;
my $AMP_START    = undef();
my $AMP_TIMEOUT  = $PUSH_TIMEOUT;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Load all defined audio files (which will kill us if they are not availble)
loadFiles(\%FILES);

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# State
my %exists   = ();
my %last     = ();
my $pullLast = time();
my $update   = 0;
my $PID      = undef();
my $NAME     = undef();
my $NEXT     = undef();
my $PID_DATA = undef();

# Always clear the RAVE and EFFECT files
if (-e $RAVE_FILE) {
	unlink($RAVE_FILE);
}
if (-e $EFFECT_FILE) {
	unlink($EFFECT_FILE);
}

# Loop forever
while (1) {

	# State is transient during a RAVE
	my $newState = 'OFF';
	%last = %exists;

	# Reduce the select delay when we're processing background effects
	# We don't want to hang waiting for event updates while we're running the show
	my $delay = $DELAY;
	if (defined($PID)) {
		$delay = 0.001;
	} elsif (defined($NEXT)) {
		$delay = 0.25;
	}

	# Wait for state updates
	{
		my $cmdState = DMX::readState($delay, \%exists, undef(), undef());
		if (defined($cmdState)) {
			$newState = $cmdState;
			$pullLast = time();
		}
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Handle "STOP" commands
	if ($newState eq 'STOP') {
		if (defined($PID)) {
			if ($DEBUG) {
				print STDERR "Ending background processing\n";
			}
			Audio::stopAll();
			kill(SIGTERM, $PID);
		}

		$update = 1;
	}

	# Reap zombie children
	if (defined($PID)) {
		my $kid = waitpid($PID, WNOHANG);
		if ($kid > 0) {
			if ($DEBUG) {
				print STDERR 'Reaped child: ' . $PID . "\n";
			}

			# Run the cleanup routine (if any)
			if ($EFFECTS{$NAME}{'done'}) {
				$EFFECTS{$NAME}{'done'}($NAME, \%exists, $EFFECTS{$NAME});
			}

			# Forget our local bypass state
			$PID      = undef();
			$NAME     = undef();
			$NEXT     = undef();
			$PID_DATA = undef();

			# Clear the RAVE and EFFECT flags
			if (-e $RAVE_FILE) {
				unlink($RAVE_FILE);
			}
			if (-e $EFFECT_FILE) {
				unlink($EFFECT_FILE);
			}
		}
	}

	# Continue special processing
	if (defined($NEXT)) {
		$NEXT->($NAME, \%exists, $EFFECTS{$NAME});
		next;
	}

	# Alert continuously on ALARM
	if ($exists{'ALARM'}) {
		$newState = 'RED_ALERT';
	}

	# Handle effects by name
	if (defined($EFFECTS{$newState})) {

		# Initiate the EFFECT state
		touch($EFFECT_FILE);

		# Store the effect name
		$NAME = $newState;

		# Dispatch the effect
		$EFFECTS{$NAME}{'cmd'}($NAME, \%exists, $EFFECTS{$NAME});

		# Clear the EFFECT state if there is no background process
		if (!defined($PID)) {
			if (-e $EFFECT_FILE) {
				unlink($EFFECT_FILE);
			}
		}

		next;
	}

	# Clear the RAVE and EFFECT flags, just in case
	if (-e $RAVE_FILE) {
		unlink($RAVE_FILE);
		die("Unexpected RAVE file\n");
	}
	if (-e $EFFECT_FILE) {
		unlink($EFFECT_FILE);
		die("Unexpected EFFECT file\n");
	}

	# Ensure our audio files are always loaded
	loadFiles(\%FILES);
}

# ======================================
# Utility routines
# ======================================
sub loadFiles($) {
	my ($files) = @_;
	foreach my $file (keys(%{$files})) {
		if (!Audio::loaded($file)) {
			Audio::load($file, $files->{$file});
		}
	}
}

sub ampWait($$$) {
	my ($name, $exists, $params) = @_;
	if ($DEBUG) {
		print STDERR "ampWait()\n";
	}

	# Ensure we don't loop forever
	if (!defined($AMP_START)) {
		$AMP_START = Time::HiRes::time();
	} elsif (Time::HiRes::time() - $AMP_START > $AMP_TIMEOUT) {
		die("Timeout waiting for amp to start\n");
	}

	# Just loop until the amp is up, then set a new "next" handler
	if ($exists{'AMPLIFIER'}) {
		if ($DEBUG) {
			print STDERR "\tAmplifier ready\n";
		}

		# Once the amp is up, be sure we've started "RAVE" mode for audio output
		if ($exists{'AUDIO_STATE'} eq 'RAVE') {
			if ($DEBUG) {
				print STDERR "\tAudio device ready\n";
			}

			# Select the next function
			if ($params->{'next'}) {
				$NEXT = $params->{'next'};
			} else {
				$NEXT = undef();
			}

			# Always wait just a bit for good luck
			sleep($AMP_DELAY / 4);
		}

		# Wait for the amp to boot if it wasn't running when we first checked
		if ($AMP_BOOTING) {
			if ($DEBUG) {
				print STDERR "\tWaiting " . $AMP_DELAY . " seconds for amp to boot\n";
			}
			sleep($AMP_DELAY);
		}

		# Reset the amp boot delay and amp start time now that it's running
		$AMP_BOOTING = 0;
		undef($AMP_START);
	} else {

		# The amp wasn't up when we checked, so it will need a boot delay
		$AMP_BOOTING = 1;
	}

	# Do not pass GO, do not collect $200
	return 1;
}

# ======================================
# Effects routines
# ======================================
sub red_alert($$$) {
	my ($name, $exists, $params) = @_;
	if ($DEBUG) {
		print STDERR "red_alert()\n";
	}

	my $ramp  = 450;
	my $sleep = $ramp;

	# Bring the B & G channels down to 0
	my @other = ();
	push(@other, { 'channel' => 13, 'value' => 0, 'time' => 0 });
	push(@other, { 'channel' => 15, 'value' => 0, 'time' => 0 });
	foreach my $data (@other) {
		DMX::dim($data);
	}

	# Set the high/low values for the ramp
	my %high = ('channel' => 14, 'value' => 255, 'time' => $ramp);
	my %low = %high;
	$low{'value'} = 64;

	# Three blasts
	for (my $i = 0 ; $i < 3 ; $i++) {
		DMX::dim(\%high);
		Audio::play($name);
		DMX::dim(\%low);
		usleep($sleep * 1000);
	}

	# Follow through on the loop
	return 0;
}

sub lsr_init($$$) {
	my ($name, $exists, $params) = @_;
	if ($DEBUG) {
		print STDERR "lsr_init()\n";
	}

	# Initiate the RAVE state
	DMX::say('Light switch rave: initiated');
	touch($RAVE_FILE);

	# Save data for future runs
	my %data = ();
	$PID_DATA = \%data;

	# Initialize the channels hash
	my %chans = ();
	foreach my $chan (@CHANNELS) {
		$chans{$chan} = 0;
	}
	$data{'channels'}      = \%chans;
	$data{'num_channels'}  = scalar(keys(%chans));
	$data{'live_channels'} = 0;

	# Dim while we wait
	my @data_set = ();
	foreach my $chan (@CHANNELS) {
		push(@data_set, { 'channel' => $chan, 'value' => 0, 'time' => $AMP_DELAY * 1000 });
	}
	DMX::applyDataset(\@data_set, 'RAVE', $OUTPUT_FILE);

	# Wait for the amp to power up
	$NEXT = \&ampWait;

	# Do not pass GO, do not collect $200
	return 1;
}

sub lsr_run($$$) {
	my ($name, $exists, $params) = @_;
	if ($DEBUG) {
		print STDERR "lsr_run()\n";
	}

	# Wait just a second for annoucements
	sleep(1);

	# Play a short burst of silence to get all the audio devices in-sync
	Audio::play('SILENCE');

	# Play the sound in the background
	Audio::background($name);

	# Record our start time
	$PID_DATA->{'start'} = Time::HiRes::time();

	# Start the main loop
	$NEXT = $params->{'loop'};

	# Do not pass GO, do not collect $200
	return 1;
}

sub lsr_loop($$$) {
	my ($name, $exists, $params) = @_;
	if ($DEBUG) {
		print STDERR "lsr_loop()\n";
	}

	# Config
	my $max_dur  = 375;
	my $max_val  = 255;
	my $reserve  = 0.75;
	my $ramp_dur = 10.40;
	my $hit_pos  = 43.35;
	my $hit_dur  = 100;
	my $fade_pos = 43.85;
	my $fade_dur = 2000;

	# How long have we been playing
	my $elapsed = Time::HiRes::time() - $PID_DATA->{'start'};
	if ($DEBUG) {
		print STDERR 'Elapsed: ' . $elapsed . "\n";
	}

	# Ramp up the number of channels in our effect
	if ($elapsed < $ramp_dur) {
		my $ratio = $PID_DATA->{'live_channels'} / ($PID_DATA->{'num_channels'} * (1 - $reserve));
		if ($PID_DATA->{'live_channels'} < 1 || $ratio < $elapsed / $ramp_dur) {
			my @keys  = keys(%{ $PID_DATA->{'channels'} });
			my $index = int(rand($PID_DATA->{'num_channels'}));
			while ($PID_DATA->{'channels'}->{ $keys[$index] } > 0) {
				$index = int(rand($PID_DATA->{'num_channels'}));
			}
			$PID_DATA->{'channels'}->{ $keys[$index] } = 1;
			$PID_DATA->{'live_channels'}++;
		}
	} else {
		if ($PID_DATA->{'live_channels'} < $PID_DATA->{'num_channels'}) {
			foreach my $chan (keys(%{ $PID_DATA->{'channels'} })) {
				$PID_DATA->{'channels'}->{$chan} = 1;
			}
			$PID_DATA->{'live_channels'} = $PID_DATA->{'num_channels'};
		}
	}

	# Prepare data for each channel
	my @data_set = ();
	my $wait     = $max_dur;
	foreach my $chan (keys(%{ $PID_DATA->{'channels'} })) {
		my $val = 0;
		my $dur = 0;

		# Random data on enabled channels until the fade
		if ($elapsed < $hit_pos) {
			if ($PID_DATA->{'channels'}->{$chan} > 0) {
				$dur = int(rand($max_dur));
				$val = int(rand($max_val));
			}
		} elsif ($elapsed < $fade_pos) {
			$val  = $max_val;
			$dur  = $hit_dur;
			$wait = ($fade_pos - $hit_pos) * 1000;
		} else {
			$val  = 0;
			$dur  = $fade_dur;
			$wait = $dur;
		}

		push(@data_set, { 'channel' => $chan, 'value' => $val, 'time' => $dur });
	}

	# Push the data set
	DMX::applyDataset(\@data_set, 'RAVE', $OUTPUT_FILE);

	# Wait for the fade interval
	usleep($wait * 1000);
}

sub lsr_done($$$) {
	my ($name, $exists, $params) = @_;
	if ($DEBUG) {
		print STDERR "lsr_done()\n";
	}
	DMX::say('Light switch rave: terminated');
}
