#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::UNIX;
use POSIX qw(ceil floor);

# Prototypes
sub mtime($);

# Config
my $TIMEOUT   = 900;
my $COUNTDOWN = 300;

# App config
my $DELAY       = 60;
my $CMD_TIMEOUT = 5;
my $TEMP_DIR    = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR = $TEMP_DIR . 'plexMonitor/';
my $CMD_FILE = $DATA_DIR . 'PROJECTOR.socket';

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
	'Timeout' => $CMD_TIMEOUT
) or die('Unable to open socket: ' . $CMD_FILE . ": ${@}\n");

# State
my $state      = 'INIT';
my $stateLast  = $state;
my $updateLast = time();
my $projector  = 0;

# Loop forever
while (1) {

	# Monitor the GUI and PLAYING files for changes only
	{
		my $mtime = mtime($DATA_DIR . 'PLAYING');
		if ($mtime > $updateLast) {
			$updateLast = $mtime;
		}
		$mtime = mtime($DATA_DIR . 'GUI');
		if ($mtime > $updateLast) {
			$updateLast = $mtime;
		}
	}

	# Monitor the PROJECTOR file for state and changes
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

		my $mtime = mtime($DATA_DIR . 'PROJECTOR');
		if ($mtime > $updateLast) {
			$updateLast = $mtime;
		}
	}

	# Calculate the new state
	my $stateLast       = $state;
	my $timeSinceUpdate = time() - $updateLast;
	if ($DEBUG) {
		print STDERR 'Time since update: ' . $timeSinceUpdate . "\n";
	}
	if ($state eq 'INIT') {
		$state = 'COUNTDOWN';
		if ($projector) {
			$state = 'ON';
		}
	} elsif ($projector) {
		if ($timeSinceUpdate > $TIMEOUT) {
			$state = 'COUNTDOWN';
			if ($timeSinceUpdate > $TIMEOUT + $COUNTDOWN) {
				$state = 'OFF';
			}
		} else {
			$state = 'ON';
		}
	} else {
		if ($timeSinceUpdate < $TIMEOUT) {
			$state = 'ON';
		}
	}

	# If the state changed, do something about if
	if ($state ne $stateLast) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		if ($state eq 'OFF') {

			# Turn off the projector
			$sock->send($state)
			  or die('Unable to write command to socket: ' . $CMD_FILE . ': ' . $state . ": ${!}\n");
		} elsif ($state eq 'ON') {

			# Do nothing, at least for the moment
		}

	}

	# Always announce a pending shutdown
	if ($state eq 'COUNTDOWN') {
		my $timeLeft = ($TIMEOUT + $COUNTDOWN) - $timeSinceUpdate;
		$timeLeft = ceil($timeLeft / 60);

		my $plural = 's';
		if ($timeLeft == 1) {
			$plural = '';
		}
		system('say', 'Projector powerdown in about ' . $timeLeft . ' minute' . $plural);
	}

	# Wait and loop
	sleep($DELAY);
}

# Cleanup
$sock->close();
undef($sock);
exit(0);

sub mtime($) {
	my ($file) = @_;
	my $mtime = 0;
	if (-r $file) {
		(undef(), undef(), undef(), undef(), undef(), undef(), undef(), undef(), undef(), $mtime, undef(), undef(), undef()) = stat($file);
	}
	return $mtime;
}
