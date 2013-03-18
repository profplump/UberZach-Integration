#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw(ceil floor);

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Config
my $TIMEOUT   = 900;
my $COUNTDOWN = 300;
my $OFF_DELAY = 60;

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'PROJECTOR_POWER';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $PROJ_SOCK    = $DATA_DIR . 'PROJECTOR.socket';
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
my $proj = DMX::clientSock($PROJ_SOCK);

# State
my $state     = 'OFF';
my $stateLast = $state;
my %exists    = ();
my %mtime     = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;
my $lastCount = 0;
my $lastUser  = time();
my $shutdown  = 0;

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, \%mtime, undef());
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Menu changes count as activity
	if ($mtime{'GUI'} && $lastUser < $mtime{'GUI'}) {
		$lastUser = $mtime{'GUI'};
	}

	# Projector starts count as activity
	if ($exists{'PROJECTOR'} && $lastUser < $mtime{'PROJECTOR'}) {
		$lastUser = $mtime{'PROJECTOR'};
	} elsif ($newState eq 'ON') {
		$lastUser = time();
	}

	# Playing counts as activity
	if ($exists{'PLAYING'} && $lastUser < time()) {
		$lastUser = time();
	}

	# Clear the shutdown timestamp if there is new user activity
	if ($shutdown && (!$exists{'PROJECTOR'} || $lastUser > $shutdown)) {
		$shutdown = 0;
	}

	# Record the shutdown timestamp
	if ($newState eq 'SHUTDOWN') {
		$shutdown = time();

		# If the projector is likely to be on, fake the flag to force a state calculation
		if ($stateLast ne 'OFF') {
			$exists{'PROJECTOR'} = 1;
		}
	}

	# Calculate the elapsed time, faking for $shutdown as needed
	my $elapsed = 0;
	if ($shutdown && $lastUser < $shutdown) {

		# Power off happens when $elapsed > $TIMEOUT + $COUNTDOWN
		# Adjust back from that for the $OFF_DELAY
		# Which gives us the number of seconds back we want to use as the start of our countdown
		# So subtract that from $shutdown, and we'll have a $lastUser timestamp substitute
		$elapsed = time() - ($shutdown - (($TIMEOUT + $COUNTDOWN) - $OFF_DELAY));
	} else {
		$elapsed = time() - $lastUser;
	}
	if ($DEBUG) {
		print STDERR 'Time since last user action: ' . $elapsed . "\n";
		if ($shutdown) {
			print STDERR 'Time since shutdown command: ' . (time() - $shutdown) . "\n";
		}
	}

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'PROJECTOR'}) {
		if ($elapsed > $TIMEOUT) {
			$state = 'COUNTDOWN';
			if ($elapsed > $TIMEOUT + $COUNTDOWN) {
				$state = 'OFF';
			}
		} else {
			$state = 'ON';
		}
	} else {
		if ($newState eq 'ON') {
			$state = 'ON';
		}
	}

	# Force updates on a periodic basis
	if (!$update && time() - $pushLast > $PUSH_TIMEOUT) {

		# Not for the projector
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
		if ($state eq 'OFF' && $exists{'PROJECTOR'}) {
			if ($DEBUG) {
				print STDERR 'Physical state mismatch: ' . $state . ':' . $exists{'PROJECTOR'} . "\n";
			}
			$update = 1;
		}
	}

	# Update the projector
	if ($update) {

		# Extra debugging to record pushes
		if ($DEBUG) {
			print STDERR 'State: ' . $state . "\n";
		}

		# Send master power state
		if ($state eq 'OFF' || $state eq 'ON') {
			$proj->send($state)
			  or die('Unable to write command to proj socket: ' . $state . ": ${!}\n");
		}

		# No output file

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}

	# Announce a pending shutdown every minute
	if ($state eq 'COUNTDOWN') {
		my $timeLeft = ($TIMEOUT + $COUNTDOWN) - $elapsed;
		$timeLeft = ceil($timeLeft / 60);

		if ($lastCount != $timeLeft) {
			my $plural = 's';
			if ($timeLeft == 1) {
				$plural = '';
			}
			system('say', 'Projector powerdown in about ' . $timeLeft . ' minute' . $plural);
			$lastCount = $timeLeft;
		}
	}
}
