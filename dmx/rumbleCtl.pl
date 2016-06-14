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

# App config
my $DATA_DIR      = DMX::dataDir();
my $STATE_SOCK    = 'RUMBLE_CTL';
my $OUT_SOCK      = 'RUMBLE';
my $OUTPUT_FILE   = $DATA_DIR . $STATE_SOCK;
my $PUSH_TIMEOUT  = 20;
my $PULL_TIMEOUT  = $PUSH_TIMEOUT * 3;
my $DELAY         = 1;
my $RAND_MAX_INT  = 30;

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
my $stateLast = $state;
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;
my $stateEnd  = 0;
my $bumpNext  = 0;

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

	# Calculate the new state, but only after the timer has elapsed
	if ($stateEnd <= $now) {
		# Pick a new delay window
		my $delay = 0;
		if (exists($exists{'RUMBLE_DELAY_MIN'})) {
			$delay = int($exists{'RUMBLE_DELAY_MIN'});
		}
		if (exists($exists{'RUMBLE_DELAY_MAX'}) && $exists{'RUMBLE_DELAY_MAX'} > $delay) {
			$delay = int(rand($exists{'RUMBLE_DELAY_MAX'} - $delay)) + $delay;
		}
		$stateEnd = $now + $delay;
		$bumpNext = 0;

		# Set the state
		$state = 'OFF';
		if ($exists{'RUMBLE_CMD'} && $exists{'RUMBLE_VALUE'}) {
			if ($exists{'RUMBLE_CMD'} =~ /^(?:LEVEL|RAW)$/) {
				$state = sprintf('%s_%d', $exists{'RUMBLE_CMD'}, int($exists{'RUMBLE_VALUE'}));
			} elsif ($exists{'RUMBLE_CMD'} eq 'RANDOM') {
				if ($exists{'RUMBLE_VALUE'} =~ /^(?:MIN|LOW|MED|FULL|HIGH)$/) {
					$state = sprintf('RANDOM_%s', $exists{'RUMBLE_VALUE'});
				}
			}
		}
	}

	# Force updates on a periodic basis
	if (!$update && $now - $pushLast > $PUSH_TIMEOUT) {
		if ($DEBUG) {
			print STDERR "Forcing periodic update\n";
		}
		$update = 1;
	}

	# Re-send the same command at randomized intervals based on user delay settings
	if ($bumpNext <= $now) {
		if ($DEBUG) {
			print STDERR "Bumping\n";
		}

		my $max = $RAND_MAX_INT;
		if ($exists{'RUMBLE_DELAY_MAX'} &&
			$exists{'RUMBLE_DELAY_MAX'} < $RAND_MAX_INT &&
			$exists{'RUMBLE_DELAY_MAX'} > 1) {
				$max = int($exists{'RUMBLE_DELAY_MAX'});
		}
		my $min = 1;
		if ($exists{'RUMBLE_DELAY_MIN'}) {
			$min = int($exists{'RUMBLE_DELAY_MIN'} / 4);
		}
		if ($min > $max) {
			$min = $max;
		}

		$bumpNext = int(rand($max - $min)) + $min - int(rand($min));
		$bumpNext += $now;
		$update = 1;
	}

	# Force updates on any state change
	if (!$update && $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		$update = 1;
	}

	# Update the rumbler
	if ($update) {

		# Send master power state
		$out->send($state)
		  or die('Unable to write command to rumble socket: ' . $state . ": ${!}\n");
		$stateLast = $state;

		# No output file
		if ($DEBUG) {
			print STDERR 'Sending rumble state: ' . $state . "\n";
		}

		# Update the push time
		$pushLast = $now;

		# Clear the update flag
		$update = 0;
	}
}
