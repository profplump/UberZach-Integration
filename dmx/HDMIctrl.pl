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
my $STATE_SOCK   = 'HDMI_CTRL';
my $HDMI_SOCK    = 'HDMI';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $PUSH_TIMEOUT = 10;
my $PULL_TIMEOUT = 60;
my $DELAY        = $PULL_TIMEOUT / 2;
my $CMD_DELAY    = 1.0;
my @INIT_CMDS    = ('POD_OFF');

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);
my $hdmi = DMX::clientSock($HDMI_SOCK);

# State
my $state     = 'PLEX';
my $stateLast = $state;
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;

# Init
foreach my $cmd (@INIT_CMDS) {
	$hdmi->send($cmd)
	  or die('Unable to write command to HDMI socket: ' . $cmd . ": ${!}\n");
}

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
	if ($exists{'GAME'}) {
		$state = 'GAME';
	} else {
		$state = 'PLEX';
	}

	# Force updates on a periodic basis
	if (!$update && $now - $pushLast > $PUSH_TIMEOUT) {
		if ($DEBUG) {
			print STDERR "Forcing periodic update\n";
		}
		$update = 1;
	}

	# Force updates on any state change
	if (!$update && $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		$update = 1;
	}

	# Rate-limit commands, in case we go dumb somewhere in the chain
	if ($update && $now < $pushLast + $CMD_DELAY) {
		if ($DEBUG) {
			print STDERR 'Ignoring overrate update: ' . $state . "\n";
		}
		$update = 0;
	}

	# Update the switch
	if ($update) {

		# Extra debugging to record pushes
		if ($DEBUG) {
			print STDERR 'State: ' . $state . "\n";
		}

		# Send state
		$hdmi->send($state)
		  or die('Unable to write command to HDMI socket: ' . $state . ": ${!}\n");

		# Update the push time
		$pushLast = $now;

		# Clear the update flag
		$update = 0;
	}
}
