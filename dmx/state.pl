#!/usr/bin/perl
use strict;
use warnings;
use IO::Select;
use IO::Socket::UNIX;
use File::Basename;
use File::Temp qw( tempfile );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Prototypes
sub mtime($);

# User config
my $STATE_TIMEOUT = 180;
my %MON_FILES     = (
	'GUI'             => 'MTIME',
	'MOTION'          => 'MTIME',
	'PROJECTOR'       => 'STATUS',
	'AMPLIFIER'       => 'STATUS',
	'PLAYING'         => 'STATUS_PLAYING',
	'NO_MOTION'       => 'EXISTS',
	'RAVE'            => 'EXISTS',
	'EFFECT'          => 'EXISTS',
	'FAN_CMD'         => 'EXISTS_ON',
	'LIGHTS'          => 'EXISTS_ON',
	'STEREO_CMD'      => 'EXISTS_ON',
	'AUDIO_AMP'       => 'EXISTS_ON',
	'AMPLIFIER_VOL'   => 'STATUS_VALUE',
	'AMPLIFIER_MODE'  => 'STATUS_VALUE',
	'AMPLIFIER_INPUT' => 'STATUS_VALUE',
	'AUDIO'           => 'STATUS_VALUE',

	'/mnt/media/DMX/cmd/GARAGE_CMD' => 'EXISTS_CLEAR',
);

# App config
my $SOCK_TIMEOUT = 5;
my $DATA_DIR     = DMX::dataDir();
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

# Socket init
my $select = DMX::stateSocket($CMD_FILE);

# Reset all dependents at starts
system($RESET_CMD);

# Subscribers
my @subscribers = ();

# State
my $state      = 'INIT';
my $stateLast  = $state;
my $status     = '';
my $statusLast = $status;
my $updateLast = 0;
my $pushLast   = 0;

# Init the file tracking structure
my %files = ();
foreach my $file (keys(%MON_FILES)) {
	my %tmp = (
		'name'   => basename($file),
		'type'   => $MON_FILES{$file},
		'path'   => $DATA_DIR . $file,
		'update' => 0,
		'status' => 0,
		'last'   => 0,
	);

	# Allow absolute paths to override the $DATA_DIR path
	if ($file =~ /^\//) {
		$tmp{'path'} = $file;
	}

	# Record the directory name for folder monitoring
	$tmp{'dir'} = dirname($tmp{'path'});

	# Push a hash ref
	$files{$file} = \%tmp;
}

# Loop forever
while (1) {

	# Provide a method to force updates even when the state does not change
	my $update = 0;

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
		$update = 1;
	}

	# Use opendir/readdir in each folder to ensure fresh results
	my %folders = ();
	foreach my $file (values(%files)) {
		if (!$folders{ $file->{'dir'} }) {
			my $dh = undef();
			if (opendir($dh, $file->{'dir'})) {
				if ($DEBUG) {
					print STDERR 'Refreshed folder: ' . $file->{'dir'} . "\n";
				}
				my @files = readdir($dh);
				closedir($dh);
			}
			$folders{ $file->{'dir'} } = 1;
		}
	}

	# Monitor files of all types
	foreach my $file (values(%files)) {

		# Always record the previous status and clear the new one
		$file->{'last'}   = $file->{'status'};
		$file->{'status'} = 0;

		# Record the last update for STATUS and MTIME files
		if ($file->{'type'} =~ /^STATUS/ || $file->{'type'} =~ /^MTIME/) {
			$file->{'update'} = mtime($file->{'path'});
			if ($DEBUG) {
				print STDERR 'Last change: ' . $file->{'name'} . ': ' . localtime($file->{'update'}) . "\n";
			}
		}

		# Grab the state from STATUS files
		if ($file->{'type'} =~ /^STATUS/) {
			my $text = '';
			{
				if (!open(my $fh, $file->{'path'})) {
					warn('Unable to open ' . $file->{'path'} . "\n");
				} else {
					local $/;
					$text = <$fh>;
					close($fh);
				}
			}

			if ($file->{'type'} eq 'STATUS_PLAYING') {
				if ($text =~ /PlayStatus\:Playing/) {
					$file->{'status'} = 1;
				}
			} elsif ($file->{'type'} eq 'STATUS_VALUE') {
				$text =~ s/\n$//;
				$file->{'status'} = $text;
			} else {
				if ($text =~ /1/) {
					$file->{'status'} = 1;
				}
			}
			if ($DEBUG) {
				print STDERR 'Status: ' . $file->{'name'} . ': ' . $file->{'status'} . "\n";
			}
		}

		# Check for the presence of EXISTS files and record their last change
		if ($file->{'type'} =~ /^EXISTS/) {
			my $mtime = mtime($file->{'path'});
			if ($mtime > 0) {
				$file->{'status'} = 1;
				$file->{'update'} = $mtime;
			} elsif ($file->{'last'}) {
				$file->{'update'} = time();
			}
			if ($DEBUG) {
				print STDERR 'Exists: ' . $file->{'name'} . ': ' . $file->{'status'} . ':' . $file->{'update'} . "\n";
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
		if ($files{'PLAYING'}->{'status'}) {
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
			if ($files{'NO_MOTION'}->{'status'}) {
				$state = 'OFF';
			} else {
				$state = 'MOTION';
			}
		}
	}
	if ($state eq 'INIT') {
		$state = 'OFF';
	}

	# Clear EXISTS_ON files when the main state is "OFF" (and before we append their status)
	foreach my $file (values(%files)) {
		if ($file->{'type'} eq 'EXISTS_ON' && $file->{'status'} && $state eq 'OFF') {
			unlink($file->{'path'});
			$file->{'stauts'} = 0;
			if ($DEBUG) {
				print STDERR 'Clearing exists flag for: ' . $file->{'name'} . "\n";
			}
		}
	}

	# Calculate the new status
	$statusLast = $status;
	{
		my @statTime = ();
		foreach my $file (values(%files)) {
			push(@statTime, $file->{'name'} . ':' . $file->{'status'} . ':' . $file->{'update'});
		}
		$status = ' (' . join(', ', @statTime) . ')';
	}

	# Clear EXISTS_CLEAR files immediately (but after we append their status)
	foreach my $file (values(%files)) {
		if ($file->{'type'} eq 'EXISTS_CLEAR' && $file->{'status'}) {
			unlink($file->{'path'});
			$file->{'stauts'} = 0;
			if ($DEBUG) {
				print STDERR 'Clearing exists flag for: ' . $file->{'name'} . "\n";
			}
		}
	}

	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		$update = 1;
	}

	# Update on any status change
	foreach my $file (values(%files)) {
		if ($file->{'status'} ne $file->{'last'}) {
			$update = 1;
			last;
		}
	}

	# Force updates on any state change
	if ($stateLast ne $state || $statusLast ne $status) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . $statusLast . ' => ' . $state . $status . "\n";
		}
		$update = 1;
	}

	# Push the update
	if ($update) {

		# Note the push
		$pushLast = time();

		# Send notifications to all subscribers
		foreach my $sub (@subscribers) {

			# Drop subscribers that are not available
			if (!eval { $sub->{'socket'}->send($state . $status) }) {
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
