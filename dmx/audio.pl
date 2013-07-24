#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw( tempfile );
use Time::HiRes qw( usleep sleep time );
use IPC::System::Simple qw( system capture );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Config
my %DEVS = (
	'AMP'     => 'Built-in Output',
	'RAVE'    => 'Built-in Output',
	'DEFAULT' => 'USB Audio CODEC ',
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'AUDIO';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $OUTPUT_STATE = $OUTPUT_FILE . '_STATE';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = 1;
my @AUDIO_CMD    = ('/Users/tv/bin/SwitchAudioSource');
my @AUDIO_GET    = (@AUDIO_CMD, '-c');
my @AUDIO_SET    = (@AUDIO_CMD, '-s');

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# State
my $state      = 'OFF';
my $stateLast  = $state;
my $device     = 'OFF';
my $deviceLast = $device;
my %exists     = ();
my $pushLast   = 0;
my $pullLast   = time();
my $update     = 0;

# Always force the output to default at launch
system(@AUDIO_SET, $DEVS{'DEFAULT'});

# Loop forever
while (1) {

	# Grab the current audio output device
	$deviceLast = $device;
	$device     = capture(@AUDIO_GET);
	$device =~ s/\n$//;

	# If the device has changed, save the state to disk
	if ($deviceLast ne $device) {
		if ($DEBUG) {
			print STDERR 'New output device: ' . $deviceLast . ' => ' . $device . "\n";
		}
		my ($fh, $tmp) = tempfile($OUTPUT_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $device . "\n";
		close($fh);
		rename($tmp, $OUTPUT_FILE);
	}

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, undef(), undef());
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'RAVE'}) {
		$state = 'RAVE';
	} elsif ($exists{'AUDIO_AMP'}) {
		$state = 'AMP';
	} else {
		$state = 'DEFAULT';
	}

	# Force updates on a periodic basis
	if (!$update && time() - $pushLast > $PUSH_TIMEOUT) {

		# Not for the audio output device
		#if ($DEBUG) {
		#	print STDERR "Forcing periodic update\n";
		#}
		#$update = 1;
	}

	# Force updates when there is a physical state mistmatch
	if (!$update && $DEVS{$state} ne $device) {
		if ($DEBUG) {
			print STDERR 'State mismatch: ' . $device . ' => ' . $DEVS{$state} . "\n";
		}
		$update = 1;
	}

	# Update the audio output device
	if ($update) {

		# Update
		if ($DEBUG) {
			print STDERR 'Setting output to: ' . $DEVS{$state} . "\n";
		}
		system(@AUDIO_SET, $DEVS{$state});

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}

	# If the state has changed and the device has responded, save to disk
	if (!$update && $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'New output state: ' . $stateLast . ' => ' . $state . "\n";
		}
		my ($fh, $tmp) = tempfile($OUTPUT_STATE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $state . "\n";
		close($fh);
		rename($tmp, $OUTPUT_STATE);
	}
}
