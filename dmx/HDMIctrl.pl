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
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;
my $CMD_DELAY    = 5.0;
my $BOOT_DELAY   = 10;
my $BOOT_TIMEOUT = $BOOT_DELAY * 3;

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
my $state     = 'OFF';
my $source    = 'PLEX';
my $stateLast = $state;
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;
my $lastBoot  = 0;

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

		# Not for HDMI
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
	if (!$update && $state ne $exists{'HDMI_SOURCE'}) {
		if ($DEBUG) {
			print STDERR 'Physical state mismatch: ' . $state . ':' . $exists{'HDMI_SOURCE'} . "\n";
		}
		$update = 1;
	}

	# Only allow updates every few seconds -- the projector goes dumb during power state changes
	if ($update && $now < $pushLast + $CMD_DELAY) {
		if ($DEBUG) {
			print STDERR 'Ignoring overrate update: ' . $state . "\n";
		}
		$update = 0;
	}

	# Update the amp
	if ($update) {

		# Extra debugging to record pushes
		if ($DEBUG) {
			print STDERR 'State: ' . $state . "\n";
		}

		# Reboot before the first update to GAME
		if (0 && $state eq 'GAME' && $lastBoot < $now - $BOOT_TIMEOUT) {
			$hdmi->send('REBOOT')
			  or die('Unable to write command to HDMI socket: ' . $state . ": ${!}\n");

			# Wait for the reboot
			sleep($BOOT_DELAY);
			$now += $BOOT_DELAY;
			$lastBoot = $now;
		}

		# Send master power state
		$hdmi->send($state)
		  or die('Unable to write command to HDMI socket: ' . $state . ": ${!}\n");

		# Update the push time
		$pushLast = $now;

		# Clear the update flag
		$update = 0;
	}
}
