#!/usr/bin/perl
use strict;
use warnings;
use IPC::System::Simple qw( system capture );
use Time::HiRes qw( usleep sleep time );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Prototypes
sub sendCmd($$);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'AMPLIFIER_POWER';
my $AMP_SOCK     = 'AMPLIFIER';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;
my $CMD_DELAY    = 1.0;
my $AUTO_CMD     = 'INPUT_AUTO';

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
my $mode      = 'SURROUND';
my $input     = 'TV';
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
	if ($newState eq 'PLAY') {
		$state = 'ON';
	} elsif ($exists{'RAVE'}) {
		$state = 'RAVE';
	} elsif ($newState eq 'PAUSE') {
		$state = 'ON';
	} else {
		$state = 'OFF';
	}

	# Calculate the channel mode
	if ($exists{'STEREO_CMD'} || $exists{'PLAYING_TYPE'} eq 'Audio' || $state eq 'RAVE') {
		$mode = 'STEREO';
	} else {
		$mode = 'SURROUND';
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

	# Set the channel mode as needed
	if ($exists{'AMPLIFIER'} && $exists{'AMPLIFIER_MODE'} ne $mode) {
		if ($DEBUG) {
			print STDERR 'Setting mode to: ' . $mode . "\n";
		}
		DMX::say('Amplifier: ' . $mode);
		sendCmd($amp, $mode);

		# Reset the input mode anytime we switch to SURROUND
		if ($mode eq 'SURROUND') {
			sendCmd($amp, $AUTO_CMD);
		}
	}

	# Set the amplifier input as needed
	if ($exists{'AMPLIFIER'} && $exists{'AMPLIFIER_INPUT'} ne $input) {
		if ($DEBUG) {
			print STDERR 'Setting input to: ' . $input . "\n";
		}
		DMX::say('Amplifier: ' . $input);
		sendCmd($amp, $input);
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
			sendCmd($amp, $cmd);
		}

		# No output file

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}
}

# Send the requested command and enforce an inter-command delay
sub sendCmd($$) {
	my ($amp, $cmd) = @_;

	# Send the command
	$amp->send($cmd)
	  or die('Unable to write command to amp socket: ' . $cmd . ": ${!}\n");
	sleep($CMD_DELAY);
}
