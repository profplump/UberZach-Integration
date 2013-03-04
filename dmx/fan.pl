#!/usr/bin/perl
use strict;
use warnings;
use IO::Select;
use File::Temp qw( tempfile );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# User config
my %DIM = (
	'OFF'    => [
		{ 'channel' => 11, 'value' => 0,   'time' => 0 }
	],
	'ON'    => [
		{ 'channel' => 11, 'value' => 255, 'time' => 0 }
	],
);

# App config
my $TEMP_DIR     = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR     = $TEMP_DIR . 'plexMonitor/';
my $STATE_SOCK   = $DATA_DIR . 'ROPE.socket';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Command-line arguments
my ($DELAY) = @ARGV;
if (!$DELAY) {
	$DELAY = $PULL_TIMEOUT / 2;
}

# Sanity check
if (!-d $DATA_DIR) {
	die("Bad config\n");
}

# Sockets
my $select = DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);
my $dmx_fh = DMX::dmxSock();

# State
my $state     = 'INIT';
my $stateLast = $state;
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();

# Always force lights out at launch
DMX::dim({ 'channel' => 11, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# Set anywhere to force an update this cycle
	my $forceUpdate = 0;

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my @ready_clients = $select->can_read($DELAY);
	foreach my $fh (@ready_clients) {

		# Read the global state
		my $cmdState = DMX::parseState($fh, \%exists);

		# We don't really care about the master state for the fan
		# But we have to parse the exists records, so we might as well grab it

		# Propogate the most recent command state
		$newState = $cmdState;
		$pullLast = time();
	}

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'FAN_CMD'}) {
		$state = 'ON';
	} else {
		$state = 'OFF';
	}
	if ($state eq 'INIT') {
		$state = 'OFF';
	}

	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		$forceUpdate = 1;
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Update the fan state
	if ($forceUpdate || $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State: ' . $stateLast . ' => ' . $state . "\n";
			DMX::printDataset($DIM{$state});
		}

		# Send the dim command
		my @values = ();
		foreach my $data (@{ $DIM{$state} }) {
			DMX::dim($data);
			push(@values, $data->{'channel'} . ' => ' . $data->{'value'} . ' @ ' . $data->{'time'});
		}

		# Save the state and value to disk
		my ($fh, $tmp) = tempfile($DATA_DIR . 'FAN.XXXXXXXX', 'UNLINK' => 0);
		print $fh 'State: ' . $state . "\n" . join("\n", @values) . "\n";
		close($fh);
		rename($tmp, $DATA_DIR . 'FAN');

		# Update the push time
		$pushLast = time();
	}
}
