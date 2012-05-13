#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::UNIX;
use POSIX qw(ceil floor);

# App config
my $DELAY    = 5;
my $TIMEOUT  = 5;
my $TEMP_DIR = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR = $TEMP_DIR . 'plexMonitor/';
my $CMD_FILE = $DATA_DIR . 'AMPLIFIER.socket';

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Sanity check
if (!-d $DATA_DIR || !-S $CMD_FILE) {
	die("Bad config\n");
}

# Socket init
my $sock = IO::Socket::UNIX->new(
	'Peer'    => $CMD_FILE,
	'Type'    => SOCK_DGRAM,
	'Timeout' => $TIMEOUT
) or die('Unable to open socket: ' . $CMD_FILE . ": ${@}\n");

# State
my $state     = 'INIT';
my $stateLast = $state;
my $projector = 0;

# Loop forever
while (1) {

	# Monitor the PROJECTOR file for state only
	{
		$projector = 0;
		my $fh;
		open($fh, $DATA_DIR . 'PROJECTOR')
		  or die("Unable to open PROJECTOR\n");
		my $text = <$fh>;
		close($fh);
		if ($text =~ /1/) {
			$projector = 1;
		}
		if ($DEBUG) {
			print STDERR 'Projector: ' . $projector . "\n";
		}
	}

	# Monitor the AMPLIFIER file for state only
	{
		$stateLast = 'OFF';
		my $fh;
		open($fh, $DATA_DIR . 'AMPLIFIER')
		  or die("Unable to open AMPLIFIER\n");
		my $text = <$fh>;
		close($fh);
		if ($text =~ /1/) {
			$stateLast = 'ON';
		}
		if ($DEBUG) {
			print STDERR 'Amplifier: ' . $stateLast . "\n";
		}
	}

	# Calculate the new state -- track the projector power state
	if ($projector) {
		$state = 'ON';
	} else {
		$state = 'OFF';
	}

	# If the state changed, do something about if
	if ($state ne $stateLast) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		if ($state eq 'OFF' || $state eq 'ON') {
			$sock->send($state)
			  or die('Unable to write command to socket: ' . $CMD_FILE . ': ' . $state . ": ${!}\n");
		}
	}

	# Wait and loop
	sleep($DELAY);
}

# Cleanup
$sock->close();
undef($sock);
exit(0);