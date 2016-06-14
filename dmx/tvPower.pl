#!/usr/bin/perl
use strict;
use warnings;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Config
my $TIMEOUT     = 900;
my $COUNTDOWN   = 119;
my $OFF_DELAY   = 15;
my $CMD_DELAY   = 10;

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'TV_POWER';
my $PROJ_SOCK    = 'TV';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;

# Prototypes
sub sayShutdown($);

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);
my $proj = DMX::clientSock($PROJ_SOCK);

# State
my $state        = 'OFF';
my $stateLast    = $state;
my %exists       = ();
my %mtime        = ();
my $pushLast     = 0;
my $pullLast     = time();
my $update       = 0;
my $lastAnnounce = 0;
my $lastUser     = time();
my $shutdown     = 0;
my $life         = 0;
my $lastPlay     = 0;

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, \%mtime, undef());

	# Avoid repeated calls to time()
	my $now = time();

	# Record only valid states
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = $now;
	}

	# Die if we don't see regular updates
	if ($now - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Menu changes count as activity
	if ($mtime{'GUI'} && $lastUser < $mtime{'GUI'}) {
		$lastUser = $mtime{'GUI'};
	}

	# TV starts count as activity
	if ($exists{'TV'} && $lastUser < $mtime{'TV'}) {
		$lastUser = $mtime{'TV'};
	} elsif ($newState eq 'ON') {
		$lastUser = $now;
	}

	# Playing counts as activity
	if ($exists{'PLAYING'} && $lastUser < $now) {
		$lastUser = $now;
	}

	# Clear the shutdown timestamp if there is new user activity
	if ($shutdown && (!$exists{'TV'} || $lastUser > $shutdown)) {
		$shutdown = 0;
	}

	# Record the shutdown timestamp, if the TV is on
	if ($newState eq 'SHUTDOWN' && $exists{'TV'}) {
		if ($DEBUG) {
			print STDERR "Recorded shutdown timestamp\n";
		}
		$shutdown = $now;
		$lastUser = $now;
	}

	# Calculate the elapsed time
	my $elapsed = $now - $lastUser;
	if ($DEBUG) {
		print STDERR 'Time since last user action: ' . $elapsed . "\n";
	}

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'TV'}) {
		if ($shutdown) {
			$state = 'SHUTDOWN';
			if ($elapsed > $OFF_DELAY) {
				$state = 'OFF';
			}
		} else {
			if ($elapsed > $TIMEOUT) {
				$state = 'COUNTDOWN';
				if ($elapsed > $TIMEOUT + $COUNTDOWN) {
					$state = 'OFF';
				}
			} else {
				$state = 'ON';
			}
		}
	} else {
		if ($newState eq 'ON') {
			$state = 'ON';
		}
	}

	# Force updates on a periodic basis
	if (!$update && $now - $pushLast > $PUSH_TIMEOUT) {

		# Not for the TV
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
	if (!$update && $state eq 'OFF' && $exists{'TV'}) {
		if ($DEBUG) {
			print STDERR 'Physical state mismatch: ' . $state . ':' . $exists{'TV'} . "\n";
		}
		$update = 1;
	}

	# Announce a pending shutdown
	if ($state eq 'COUNTDOWN' || $state eq 'SHUTDOWN') {
		my $timeLeft = 0;
		if ($state eq 'SHUTDOWN') {
			$timeLeft = $OFF_DELAY - $elapsed;
		} else {
			$timeLeft = ($TIMEOUT + $COUNTDOWN) - $elapsed;
		}
		sayShutdown($timeLeft / 60);
	}

	# Only allow updates to "ON" or "OFF" -- the TV knows no other states
	if ($update && ($state ne 'ON' && $state ne 'OFF')) {
		if ($DEBUG) {
			print STDERR 'Ignoring update state other than ON/OFF: ' . $state . "\n";
		}
		$update = 0;
	}

	# Only allow updates every few seconds -- the TV goes dumb during power state changes
	if ($update && $now < $pushLast + $CMD_DELAY) {
		if ($DEBUG) {
			print STDERR 'Ignoring overrate update: ' . $state . "\n";
		}
		$update = 0;
	}

	# Update the TV
	if ($update) {

		# Extra debugging to record pushes
		if ($DEBUG) {
			print STDERR 'State: ' . $state . "\n";
		}

		# Send master power state
		$proj->send($state)
		  or die('Unable to write command to proj socket: ' . $state . ": ${!}\n");

		# Annouce the state change, after the fact
		DMX::say('TV ' . $state);

		# No output file

		# Update the push time
		$pushLast = $now;

		# Clear the lastAnnounce timer
		$lastAnnounce = 0;

		# Clear the update flag
		$update = 0;
	}
}

sub sayShutdown($) {
	my ($minutesLeft) = @_;

	# Only allow annoucements once per minute
	my $now = time();
	if ($now < $lastAnnounce + 60) {
		return;
	}
	$lastAnnounce = $now;

	# Determine the unit
	my $unit     = 'minute';
	my $timeLeft = $minutesLeft;
	if ($minutesLeft < 1) {
		$timeLeft = $minutesLeft * 60;
		$unit     = 'second';
	}

	# Avoid saying "0" unless we *really* mean it
	$timeLeft = ceil($timeLeft);

	# Add an "s" as needed
	my $plural = 's';
	if ($timeLeft == 1) {
		$plural = '';
	}
	$unit .= $plural;

	# Speak
	DMX::say('TV shutdown in about ' . $timeLeft . ' ' . $unit);
}
