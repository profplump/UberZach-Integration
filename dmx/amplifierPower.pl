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
sub sendCmd($);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'AMPLIFIER_POWER';
my $AMP_SOCK     = 'AMPLIFIER';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;
my $CMD_DELAY    = 5.0;
my $AUTO_CMD     = 'INPUT_AUTO';

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);
my $AMP = DMX::clientSock($AMP_SOCK);

# State
my $power     = 'OFF';
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();
my $lastMode  = 0;
my $modeCmd   = undef();
my $lastInput = 0;
my $inputCmd  = undef();
my $lastPower = 0;
my $powerCmd  = undef();

# Loop forever
while (1) {

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, undef(), undef());

	# Avoid repeated calls to time()
	my $now = time();

	# Record only valid states
	my $newState = undef();
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Die if we don't see regular updates
	if ($now - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Set the power state as needed
	my $powerCmd = undef();
	{
		my $power = 'OFF';
		if ($newState eq 'PLAY') {
			$power = 'ON';
		} elsif ($exists{'RAVE'}) {
			$power = 'ON';
		} elsif ($newState eq 'PAUSE') {
			$power = 'ON';
		}
		if (($power eq 'OFF' && $exists{'AMPLIFIER'}) || ($power eq 'ON' && !$exists{'AMPLIFIER'})) {
			$powerCmd = $power;
		}
	}

	# Set the channel mode as needed
	my $modeCmd = undef();
	{
		my $mode = 'SURROUND';
		if ($exists{'STEREO_CMD'} || $exists{'PLAYING_TYPE'} eq 'audio' || $exists{'RAVE'}) {
			$mode = 'STEREO';
		}
		if ($exists{'AMPLIFIER'} && $exists{'AMPLIFIER_MODE'} ne $mode) {
			$modeCmd = $mode;
		}
	}

	# Set the input as needed
	my $inputCmd = undef();
	{
		my $input = 'TV';
		if ($exists{'GAME'}) {
			$input = 'GAME';
		}
		if ($exists{'AMPLIFIER'} && $exists{'AMPLIFIER_INPUT'} ne $input) {
			$inputCmd = $input;
		}
	}

	# Update the amp
	if ($powerCmd || $inputCmd || $modeCmd) {

		# Send master power state
		if (defined($powerCmd) && $lastPower < $now - $CMD_DELAY) {
			$lastPower = $now;
			if ($DEBUG) {
				print STDERR 'State: ' . $power . "\n";
			}
			sendCmd($powerCmd);
		}

		# Send the output state
		if (defined($modeCmd) && $lastMode < $now - $CMD_DELAY) {
			$lastMode = $now;
			if ($DEBUG) {
				print STDERR 'Setting mode to: ' . $modeCmd . "\n";
			}
			sendCmd($modeCmd);

			# Reset the input mode anytime we switch to SURROUND
			if ($modeCmd eq 'SURROUND') {
				sendCmd($AUTO_CMD);
			}
		}

		# Send the input state
		if ($inputCmd && $lastInput < $now - $CMD_DELAY) {
			$lastInput = $now;
			if ($DEBUG) {
				print STDERR 'Setting input to: ' . $inputCmd . "\n";
			}
			sendCmd($inputCmd);
		}


		# No output file

		# Update the push time
		$pushLast = $now;
	}
}

# Send the requested command and enforce an inter-command delay
sub sendCmd($$) {
	my ($cmd) = @_;

	# Send the command
	$AMP->send($cmd)
	  or die('Unable to write command to amp socket: ' . $cmd . ": ${!}\n");

	# A tiny delay to keep the serial port stable in repeated calls
	sleep(0.1);
}
