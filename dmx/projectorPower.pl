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
my $OFF_DELAY = 15;

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'PROJECTOR_POWER';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $PROJ_SOCK    = $DATA_DIR . 'PROJECTOR.socket';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;

# Prototypes
sub say($);
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

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	{
		my %mtimeTmp  = ();
		my %existsTmp = ();
		my $cmdState = DMX::readState($DELAY, \%existsTmp, \%mtimeTmp, undef());
		if (defined($cmdState)) {
			$newState = $cmdState;
			$pullLast = time();
		}

		# Only record valid exists/mtime hashes
		if (scalar(keys(%existsTmp)) > 0) {
			%mtime  = %mtimeTmp;
			%exists = %existsTmp;
		}
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

	# Record the shutdown timestamp, if the projector is on
print STDERR 'NewState: ' . $newState . "\n";
	if ($newState eq 'SHUTDOWN' && $exists{'PROJECTOR'}) {
		if ($DEBUG) {
			print STDERR "Recorded shutdown timestamp\n";
		}
		$shutdown = time();
		$lastUser = $shutdown;
} elsif ($newState eq 'SHUTDOWN') {
print STDERR "Not recording shutdown because exists is false?\n";
	}

	# Calculate the elapsed time
	my $elapsed = time() - $lastUser;
	if ($DEBUG) {
		print STDERR 'Time since last user action: ' . $elapsed . "\n";
	}

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'PROJECTOR'}) {
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

	# Only allow updates to "ON" or "OFF" -- the projector knows no other states
	if ($update && ($state ne 'ON' && $state ne 'OFF')) {
		$update = 0;
	}

	# Update the projector
	if ($update) {

		# Extra debugging to record pushes
		if ($DEBUG) {
			print STDERR 'State: ' . $state . "\n";
		}

		# Send master power state
		say('Projector ' . $state);
		$proj->send($state)
		  or die('Unable to write command to proj socket: ' . $state . ": ${!}\n");

		# No output file

		# Update the push time
		$pushLast = time();

		# Clear the lastAnnounce timer
		$lastAnnounce = 0;

		# Clear the update flag
		$update = 0;
	}
}

# Speak
sub say($) {
	my ($str) = @_;

	if ($DEBUG) {
		print STDERR 'Say: ' . $str . "\n";
	}
	system('say', $str);
}

sub sayShutdown($) {
	my ($minutesLeft) = @_;

	# Only allow annoucements once per minute
	if (time() < $lastAnnounce + 60) {
		return;
	}
	$lastAnnounce = time();

	# Determine the unit
	my $unit     = 'minute';
	my $timeLeft = ceil($minutesLeft);
	if ($minutesLeft < 1) {
		$timeLeft = $minutesLeft * 60;
		$unit     = 'second';
	}

	# Add an "s" as needed
	my $plural = 's';
	if ($timeLeft == 1) {
		$plural = '';
	}
	$unit .= $plural;

	# Speak
	say('Projector shutdown in about ' . $timeLeft . ' ' . $unit);
}
