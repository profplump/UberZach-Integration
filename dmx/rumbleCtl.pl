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
my $STATE_SOCK   = 'RUMBLE_CTL';
my $OUT_SOCK     = 'RUMBLE';
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
my $out = DMX::clientSock($OUT_SOCK);

# State
my $state     = 'OFF';
my $mode      = 'SURROUND';
my $input     = 'TV';
my $stateLast = $state;
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;
my $lastMode  = 0;
my $lastInput = 0;
my $lastPower = 0;

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, undef(), undef());

	# Avoid repeated calls to time()
	my $now = time();

	# Record only valid states
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Die if we don't see regular updates
	if ($now - $pullLast > $PULL_TIMEOUT) {
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
	if (!$update && $now - $pushLast > $PUSH_TIMEOUT) {

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

	# Update the rumble
	if ($update) {

		# Send master power state
		my $cmd = $state;
		if (!$state) {
			$cmd = 'OFF';
		}
		sendCmd($out, $cmd);

		# No output file

		# Update the push time
		$pushLast = $now;

		# Clear the update flag
		$update = 0;
	}
}
