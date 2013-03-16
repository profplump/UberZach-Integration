#!/usr/bin/perl
use strict;
use warnings;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Config
my $USB_DEV     = 'USB Audio CODEC ';
my $AMP_DEV     = 'Built-in Output';
my $DEFAULT_DEV = $USB_DEV;
my $RAVE_DEV    = $AMP_DEV;

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'AMPLIFIER_POWER';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $AMP_SOCK     = $DATA_DIR . 'AMPLIFIER.socket';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;
my $START_DELAY  = 3.5;
my @AUDIO_SET    = ('SwitchAudioSource', '-s');

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);
my $amp = DMX::clientSock($AMP_SOCK);

# State
my $state     = 'OFF';
my $stateLast = $state;
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, undef());
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
	if ($newState eq 'PLAY') {
		$state = 'ON';
	} elsif ($exists{'RAVE'}) {
		$state = 'RAVE';
	} elsif ($newState eq 'PAUSE') {
		$state = 'ON';
	} else {
		$state = 'OFF';
	}

	# Force updates on a periodic basis
	if (!$update && time() - $pushLast > $PUSH_TIMEOUT) {

		# Not for the amp
		#if ($DEBUG) {
		#	print STDERR "Forcing periodic update\n";
		#}
		#$update = 1;
	}

	# Force updates on any state change
	if (!$update && $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		$update = 1;
	}

	# Force updates when there is a physical state mistmatch
	if (!$update) {
		if (($state eq 'OFF' && $exists{'AMPLIFIER'}) || ($state eq 'ON' && !$exists{'AMPLIFIER'})) {
			if ($DEBUG) {
				print STDERR 'Physical state mismatch: ' . $state . ':' . $exists{'AMPLIFIER'} . "\n";
			}
			$update = 1;
		}
	}

	# Update the amp
	if ($update) {

		# Extra debugging to record pushes
		if ($DEBUG) {
			print STDERR 'State: ' . $state . "\n";
		}

		# Send master power state
		my $cmd = undef();
		if ($state eq 'OFF' || $state eq 'ON') {
			$cmd = $state;
		} elsif ($state eq 'RAVE') {
			$cmd = 'ON';
		}
		if (defined($cmd)) {
			$amp->send($cmd)
			  or die('Unable to write command to amp socket: ' . $cmd . ": ${!}\n");
		}

		# Select an output device
		if ($state eq 'RAVE') {
			my @CMD = @AUDIO_SET;
			push(@CMD, $RAVE_DEV);
			system(@CMD);

		} else {
			if (defined($cmd) && $cmd eq 'ON') {
				# Set the audio source back to the default
				my @CMD = @AUDIO_SET;
				push(@CMD, $DEFAULT_DEV);
				system(@CMD);
			}
		}

		# Reset to TV @ 5.1 at power on
		if (defined($cmd) && $cmd eq 'ON') {

			# Wait for the amp to boot
			if (!$exists{'AMPLIFIER'}) {
				sleep($START_DELAY);
			}

			# Set the mode
			$amp->send('TV')
			  or die('Unable to write command to amp socket: TV' . ": ${!}\n");
			$amp->send('SURROUND')
			  or die('Unable to write command to amp socket: SURROUND' . ": ${!}\n");
		}

		# Rave through the main amp
		if ($state eq 'RAVE') {

			# Set the mode
			$amp->send('TV')
			  or die('Unable to write command to amp socket: TV' . ": ${!}\n");
			$amp->send('STEREO')
			  or die('Unable to write command to amp socket: STEREO' . ": ${!}\n");
		}

		# No output file

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}
}
