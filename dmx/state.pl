#!/usr/bin/perl
use strict;
use warnings;
use IO::Select;
use IO::Socket::UNIX;
use File::Temp qw( tempfile );

# Prototypes
sub mtime($);

# User config
my $STATE_TIMEOUT = 180;

# App config
my $SOCK_TIMEOUT = 5;
my $TEMP_DIR     = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR     = $TEMP_DIR . 'plexMonitor/';
my $CMD_FILE     = $DATA_DIR . 'STATE.socket';
my $MAX_CMD_LEN  = 4096;
my $RESET_CMD    = $ENV{'HOME'} . '/bin/video/dmx/reset.sh';
my $PUSH_TIMEOUT = 20;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Command-line arguments
my ($DELAY) = @ARGV;
if (!$DELAY) {
	$DELAY = 0.5;
}

# Sanity check
if (!-d $DATA_DIR) {
	die("Bad config\n");
}

# Socket init
if (-e $CMD_FILE) {
	unlink($CMD_FILE);
}
my $sock = IO::Socket::UNIX->new(
	'Local' => $CMD_FILE,
	'Type'  => SOCK_DGRAM
) or die('Unable to open socket: ' . $CMD_FILE . ": ${@}\n");
if (!-S $CMD_FILE) {
	die('Failed to create socket: ' . $CMD_FILE . "\n");
}
my $select = IO::Select->new($sock)
  or die('Unable to select socket: ' . $CMD_FILE . ": ${!}\n");

# Reset all dependents at starts
system($RESET_CMD);

# Subscribers
my @subscribers = ();

# State
my $state      = 'INIT';
my $stateLast  = $state;
my $playing    = 0;
my $projector  = 0;
my $updateLast = 0;
my $pushLast   = 0;

# Loop forever
while (1) {

	# Provide a method to force updates even when the state does not change
	my $forceUpdate = 0;

	# Check for queued commands
	my @ready_clients = $select->can_read($DELAY);
	foreach my $fh (@ready_clients) {

		# Grab the inbound text
		my $path = undef();
		$fh->recv($path, $MAX_CMD_LEN);
		$path =~ s/^\s+//;
		$path =~ s/\s+$//;
		if ($DEBUG) {
			print STDERR 'Got path: ' . $path . "\n";
		}

		# Only accept valid paths
		if (!-r $path) {
			print STDERR 'Invalid socket path: ' . $path . "\n";
			next;
		}

		# Open the new socket
		my $sub = IO::Socket::UNIX->new(
			'Peer'    => $path,
			'Type'    => SOCK_DGRAM,
			'Timeout' => $SOCK_TIMEOUT
		);
		if (!$sub) {
			print STDERR 'Unable to open socket: ' . $path . ": ${@}\n";
			next;
		}

		# Add the socket to our subscriber list
		my %tmp = (
			'path'   => $path,
			'socket' => $sub,
		);
		push(@subscribers, \%tmp);

		# Force an update
		$forceUpdate = 1;
	}

	# Monitor the PLAY_STATUS file for changes and state
	{
		my $mtime = mtime($DATA_DIR . 'PLAY_STATUS');
		if ($mtime > $updateLast) {
			$updateLast = $mtime;
		}

		# Grab the PLAY_STATUS value
		$playing = 0;
		my $fh;
		open($fh, $DATA_DIR . 'PLAY_STATUS')
		  or die("Unable to open PLAY_STATUS\n");
		my $text = <$fh>;
		close($fh);
		if ($text =~ /1/) {
			$playing = 1;
		}
		if ($DEBUG) {
			print STDERR 'Playing: ' . $playing . "\n";
		}
	}

	# Monitor the PROJECTOR file for changes and state
	{
		my $mtime = mtime($DATA_DIR . 'PROJECTOR');
		if ($mtime > $updateLast) {
			$updateLast = $mtime;
		}

		# Grab the PROJECTOR value
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

	# Monitor the GUI, PLAYING, and MOTION files for changes only
	{
		my $mtime = mtime($DATA_DIR . 'PLAYING');
		if ($mtime > $updateLast) {
			$updateLast = $mtime;
		}
		$mtime = mtime($DATA_DIR . 'GUI');
		if ($mtime > $updateLast) {
			$updateLast = $mtime;
		}
		$mtime = mtime($DATA_DIR . 'MOTION');
		if ($mtime > $updateLast) {
			$updateLast = $mtime;
		}
	}

	# Calculate the new state
	$stateLast = $state;
	if ($projector) {

		# We are always either playing or paused if the projector is on
		if ($playing) {
			$state = 'PLAY';
		} else {
			$state = 'PAUSE';
		}

	} else {

		# If the projector is off, check the timeouts
		my $timeSinceUpdate = time() - $updateLast;
		if ($timeSinceUpdate > $STATE_TIMEOUT) {
			$state = 'OFF';
		} elsif ($timeSinceUpdate < $STATE_TIMEOUT) {
			$state = 'MOTION';
		}
	}
	if ($state eq 'INIT') {
		$state = 'OFF';
	}

	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		$forceUpdate = 1;
	}

	# Update the state
	if ($forceUpdate || $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State: ' . $stateLast . ' => ' . $state . "\n";
		}

		# Note the push
		$pushLast = time();

		# Send notifications to all subscribers
		foreach my $sub (@subscribers) {

			# Drop subscribers that are not available
			if (!eval { $sub->{'socket'}->send($state) }) {
				print STDERR 'Dropping bad socket from subscriber list: ' . $sub->{'path'} . "\n";

				my @new_subscribers = ();
				foreach my $new (@subscribers) {
					if ($new->{'socket'} eq $sub->{'socket'}) {
						next;
					}
					push(@new_subscribers, $new);
				}
				@subscribers = @new_subscribers;
			}
		}

		# Save the state and value to disk
		my ($fh, $tmp) = tempfile($DATA_DIR . 'STATE.XXXXXXXX', 'UNLINK' => 0);
		print $fh $state . "\n";
		close($fh);
		rename($tmp, $DATA_DIR . 'STATE');
	}
}

sub mtime($) {
	my ($file) = @_;
	my $mtime = 0;
	if (-r $file) {
		(undef(), undef(), undef(), undef(), undef(), undef(), undef(), undef(), undef(), $mtime, undef(), undef(), undef()) = stat($file);
	}
	return $mtime;
}
