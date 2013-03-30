#!/usr/bin/perl
use strict;
use warnings;
use POSIX;
use File::Touch;
use Time::HiRes qw( usleep );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Prototypes
sub red_alert($$);
sub rave_init($$);
sub lsr_loop();

# User config
my @CHANNELS = (1, 2, 4, 5, 6, 7, 8, 9, 13, 14, 15);
my %EFFECTS = (
	'RED_ALERT' => { 'cmd' => \&red_alert },
	'LSR'       => { 'cmd' => \&rave_init, 'file' => '/mnt/media/DMX/Rave.mp3', 'next' => \&lsr_loop },
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'RAVE_CMD';
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

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# State
my %exists   = ();
my $pullLast = time();
my $update   = 0;
my $PID      = undef();
my $EFFECT   = undef();
my $PID_DATA = undef();

# Always clear the RAVE file
if (-e $RAVE_FILE) {
	unlink($RAVE_FILE);
}

# Loop forever
while (1) {

	# State is transient during a RAVE
	my $newState = 'OFF';

	# Reduce the select delay when we're processing background effects
	# We don't want to hang waiting for event updates while we're running the show
	my $delay = $DELAY;
	if (defined($PID)) {
		$delay = 0.001;
	}

	# Wait for state updates
	{
		my %existsTmp = ();
		my $cmdState = DMX::readState($delay, \%existsTmp, undef(), undef());
		if (defined($cmdState)) {
			$newState = $cmdState;
			$pullLast = time();
		}

		# Only record valid exists hashes
		if (scalar(keys(%existsTmp)) < 1) {
			%exists = %existsTmp;
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

			# Forget our local bypass state
			$PID      = undef();
			$EFFECT   = undef();
			$PID_DATA = undef();

			# Clear the RAVE flag
			if (-e $RAVE_FILE) {
				unlink($RAVE_FILE);
			}
		}
	}

	# Continue special processing
	if (defined($EFFECT)) {
		$EFFECT->();
		next;
	}

	# Handle effects by name
	if (defined($EFFECTS{$newState})) {

		# Initiate the RAVE state
		touch($RAVE_FILE);

		# Dispatch the effect
		$EFFECTS{$newState}{'cmd'}(\%exists, $EFFECTS{$newState});

		# Clear the RAVE state if there is no background process
		if (!defined($PID)) {
			unlink($RAVE_FILE);
		}

		next;
	}

	# Clear the RAVE flag, just in case
	if (-e $RAVE_FILE) {
		unlink($RAVE_FILE);
		die("Unexpected RAVE file\n");
	}
}

# ======================================
# Effects routines
# ======================================
sub red_alert($$) {
	my ($exists, $effect) = @_;
	if ($DEBUG) {
		print STDERR "red_alert()\n";
	}

	my $file  = '/mnt/media/DMX/Red Alert.mp3';
	my @sound = ('afplay', $file);
	my $ramp  = 450;
	my $sleep = $ramp;

	# Stat the file to bring the network up-to-date
	stat($file);

	# Bring the B & G channels down to 0
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

sub rave_init($$) {
	my ($exists, $effect) = @_;
	if ($DEBUG) {
		print STDERR "rave_init()\n";
	}
	if (!defined($effect->{'file'}) || !-r $effect->{'file'}) {
		die('Invalid RAVE audio file: ' . $effect->{'file'} . "\n");
	}

	# Config
	my $SND_APP   = 'afplay';
	my $SILENCE   = '/mnt/media/DMX/Silence.wav';
	my $SIL_DELAY = 1.3;
	my $AMP_SHORT = 5;
	my $AMP_LONG  = $AMP_SHORT + 5;

	# Stat the file to bring the network up-to-date
	stat($SILENCE);
	stat($effect->{'file'});

	# Setup our loop handler
	if ($effect->{'next'}) {
		$EFFECT = $effect->{'next'};
	}

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

	# Reduce the amp delay if the amp is already on
	my $amp_wait = $AMP_LONG;
	if ($exists->{'AMPLIFIER'}) {
		$amp_wait = $AMP_SHORT;
	}

	# Dim while we wait
	my @data_set = ();
	foreach my $chan (@CHANNELS) {
		push(@data_set, { 'channel' => $chan, 'value' => 0, 'time' => $amp_wait / 2 * 1000 });
	}
	DMX::applyDataset(\@data_set, 'RAVE', $OUTPUT_FILE);

	# Wait for the amp to power up
	if ($DEBUG) {
		print STDERR 'Waiting ' . $amp_wait . " seconds for the amp to boot\n";
	}
	sleep($amp_wait - $SIL_DELAY);

	# Play a short burst of silence to get all the audio in-sync
	my @sound = ($SND_APP, $SILENCE);
	system(@sound);

	# Play the sound in a child (i.e. in the background)
	$PID = fork();
	if (defined($PID) && $PID == 0) {
		my @sound = ($SND_APP, $effect->{'file'});
		exec(@sound)
		  or die('Unable to play sound: ' . join(' ', @sound) . "\n");
	}

	# Record our start time
	$data{'start'} = Time::HiRes::time();

	# Do not pass GO, do not collect $200
	return 1;
}

sub lsr_loop() {
	if ($DEBUG) {
		print STDERR "lsr_loop()\n";
	}

	# Config
	my $max_dur  = 375;
	my $max_val  = 255;
	my $reserve  = 0.75;
	my $ramp_dur = 10.20;
	my $hit_pos  = 43.15;
	my $hit_dur  = 100;
	my $fade_pos = 43.65;
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
