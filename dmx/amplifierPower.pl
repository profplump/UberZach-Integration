#!/usr/bin/perl
use strict;
use warnings;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'AMPLIFIER_POWER';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $AMP_SOCK     = $DATA_DIR . 'AMPLIFIER.socket';
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

	# Calculate the new state
	$stateLast = $state;
	if ($newState eq 'ON' || $exists{'RAVE'}) {
		$state = 'ON';
	} else {
		$state = 'OFF';
	}


	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		# Not for the amp
		#$update = 1;
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Force updates on any state change
	if ($stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		$update = 1;
	}

	# Update the amp
	if ($update) {

		# Extra debugging to record pushes
		if ($DEBUG) {
			print STDERR 'State: ' . $state . "\n";
		}

		# Send master power state
		if ($state eq 'OFF' || $state eq 'ON') {
			$amp->send($state)
			  or die('Unable to write command to amp socket: ' . $state . ": ${!}\n");
		}

		# Reset to TV @ 5.1 at power on
		if ($state eq 'ON') {
			# Wait for the amp to boot
			sleep($DELAY);
			$amp->send('TV')
			  or die('Unable to write command to amp socket: TV' . ": ${!}\n");
			$amp->send('SURROUND')
			  or die('Unable to write command to amp socket: SURROUND' . ": ${!}\n");
		}

		# No output file

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}
}
