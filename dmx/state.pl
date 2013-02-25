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
my %MON_FILES = (
	'PLAYING'     => 'MTIME',
	'GUI'         => 'MTIME',
	'MOTION'      => 'MTIME',
	'PROJECTOR'   => 'STATUS',
	'PLAY_STATUS' => 'STATUS',
	'LIGHTS'      => 'EXISTS',
	'FAN_CMD'     => 'EXISTS',
);


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
my $updateLast = 0;
my $pushLast   = 0;

# Init the file tracking structure
my %files = ();
foreach my $file (keys(%MON_FILES)) {
	my %tmp = (
		'name'   => $file,
		'type'   => $MON_FILES{$file},
		'path'   => $DATA_DIR . $file,
		'update' => 0,
		'status' => 0,
		'last'   => 0,
	);
	$files{$file} = \%tmp;
}

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

	# Monitor files of all types
	foreach my $file (values(%files)) {
		# Always record the previous status and clear the new one
		$file->{'last'} = $file->{'status'};
		$file->{'status'} = 0;

		# Record the last update
		if ($file->{'type'} eq 'STATUS' || $file->{'type'} eq 'MTIME') {
			$file->{'update'} = mtime($file->{'path'});
			if ($DEBUG) {
				print STDERR 'Last change: ' . $file->{'name'} . ': ' . localtime($file->{'update'}) . "\n";
			}
		}

		# Grab the new status and save the old one
		if ($file->{'type'} eq 'STATUS') {
			my $fh;
			open($fh, $file->{'path'})
			  or die('Unable to open ' . $file->{'path'} . "\n");
			my $text = <$fh>;
			close($fh);
			if ($text =~ /1/) {
				$file->{'status'} = 1;
			}
			if ($DEBUG) {
				print STDERR 'Status: ' . $file->{'name'} . ': ' . $file->{'status'} . "\n";
			}
		}

		# Check for the presence of a file
		if ($file->{'type'} eq 'EXISTS') {
			if (-e $file->{'path'}) {
				$file->{'status'} = 1;
			}
			if ($DEBUG) {
				print STDERR 'Exists: ' . $file->{'name'} . ': ' . $file->{'status'} . "\n";
			}
		}
	}

	# Set the global update timestamp
	foreach my $file (values(%files)) {
		if ($file->{'update'} > $updateLast) {
			$updateLast = $file->{'update'};
		}
	}

	# Calculate the new state
	$stateLast = $state;
	if ($files{'PROJECTOR'}->{'status'}) {

		# We are always either playing or paused if the projector is on
		if ($files{'PLAY_STATUS'}->{'status'}) {
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

	# Clear exists files when the main state is "OFF"
	foreach my $file (values(%files)) {
		if ($file->{'type'} eq 'EXISTS' && $file->{'status'} && $state eq 'OFF') {
			unlink($file->{'path'});
			$file->{'stauts'} = 0;
			if ($DEBUG) {
				print STDERR 'Clearing exists flag for: ' . $file->{'name'} . "\n";
			}
		}
	}

	# Append the status of all "exists" files
	{
		my @exists = ();
		foreach my $file (values(%files)) {
			if ($file->{'type'} eq 'EXISTS') {
				push(@exists, $file->{'name'} . ':' . $file->{'status'});
			}
		}
		$state .= ' (' . join(', ', @exists) . ')';
	}

	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		$forceUpdate = 1;
	}

	# Update on any status change
	foreach my $file (values(%files)) {
		if ($file->{'status'} != $file->{'last'}) {
			$forceUpdate = 1;
			last;
		}
	}

	# Update the state
	if ($forceUpdate || $state ne $stateLast) {
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
