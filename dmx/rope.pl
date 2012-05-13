#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket;
use Time::HiRes qw( usleep );
use File::Temp qw( tempfile );

# Prototypes
sub mtime($);
sub dim($$$);

# Channels:
#	0 => All channels
#	1 => Couch-side hidden
#	2 => Couch-side exposed
#	3 => Stairs
#	4 => <Unused>
#	5 => Bar-side hidden
#	6 => Bar-side bar-shelves
#	7 => Bar-side exposed
#	8 => Bar-side ceiling

# User config
my %DIM = (
	'OFF'    => [
		{ 'channel' => 0, 'value' => 0,   'time' => 60000 }
	],
	'PLAY'      => [
		{ 'channel' => 1, 'value' => 64,  'time' => 500   },
		{ 'channel' => 2, 'value' => 32,  'time' => 500   },
		{ 'channel' => 3, 'value' => 80,  'time' => 1500  },
		{ 'channel' => 5, 'value' => 64,  'time' => 500   },
		{ 'channel' => 6, 'value' => 36,  'time' => 500   },
		{ 'channel' => 7, 'value' => 32,  'time' => 500   },
		{ 'channel' => 8, 'value' => 16,  'time' => 500   },
	],
	'PLAY_HIGH' => [
		{ 'channel' => 1, 'value' => 255, 'time' => 500   },
		{ 'channel' => 2, 'value' => 128, 'time' => 500   },
		{ 'channel' => 3, 'value' => 192, 'time' => 1500  },
		{ 'channel' => 5, 'value' => 128, 'time' => 500   },
		{ 'channel' => 6, 'value' => 36,  'time' => 500   },
		{ 'channel' => 7, 'value' => 128, 'time' => 500   },
		{ 'channel' => 8, 'value' => 16,  'time' => 500   },
	],
	'PAUSE'     => [
		{ 'channel' => 1, 'value' => 255, 'time' => 1000  },
		{ 'channel' => 2, 'value' => 192, 'time' => 10000 },
		{ 'channel' => 3, 'value' => 192, 'time' => 5000  },
		{ 'channel' => 5, 'value' => 255, 'time' => 1000  },
		{ 'channel' => 6, 'value' => 104, 'time' => 12000 },
		{ 'channel' => 7, 'value' => 192, 'time' => 10000 },
		{ 'channel' => 8, 'value' => 92,  'time' => 16000 },
	],
	'MOTION'    => [
		{ 'channel' => 1, 'value' => 255, 'time' => 1000  },
		{ 'channel' => 2, 'value' => 192, 'time' => 1000  },
		{ 'channel' => 3, 'value' => 192, 'time' => 1000  },
		{ 'channel' => 5, 'value' => 192, 'time' => 1000  },
		{ 'channel' => 6, 'value' => 104, 'time' => 1000  },
		{ 'channel' => 7, 'value' => 192, 'time' => 1000  },
		{ 'channel' => 8, 'value' => 92,  'time' => 1000  },
	],
);
my $TIMEOUT = 180;

# App config
my $SOCK_TIMEOUT = 5;
my $TEMP_DIR     = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR = $TEMP_DIR . 'plexMonitor/';
my $CMD_FILE = $DATA_DIR . 'DMX.socket';

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
$DELAY *= 1000000;    # Microseconds;

# Sanity check
if (!-d $DATA_DIR || !-S $CMD_FILE) {
	die("Bad config\n");
}

# Socket init
my $sock = IO::Socket::UNIX->new(
	'Peer'    => $CMD_FILE,
	'Type'    => SOCK_DGRAM,
	'Timeout' => $SOCK_TIMEOUT
) or die('Unable to open socket: ' . $CMD_FILE . ": ${@}\n");

# State
my $state      = 'INIT';
my $stateLast  = $state;
my $playing    = 0;
my $projector  = 0;
my $lights     = 0;
my $updateLast = 0;

# Always force lights out at launch
dim(0, 0, 0);

# Loop forever
while (1) {

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

	# Monitor the LIGHTS file for presence
	{
		$lights = 0;
		if (-e $DATA_DIR . 'LIGHTS') {
			$lights = 1;
		}
		if ($DEBUG) {
			print STDERR 'Lights: ' . $lights . "\n";
		}

		# Clear the override when the projector is off
		if ($lights && !$projector) {
			unlink($DATA_DIR . 'LIGHTS');
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

			# Allow an override to higher brightness during playback
			if ($lights) {
				$state = 'PLAY_HIGH';
			} else {
				$state = 'PLAY';
			}
		} else {
			$state = 'PAUSE';
		}

	} else {

		# If the projector is off, check the timeouts
		my $timeSinceUpdate = time() - $updateLast;
		if ($timeSinceUpdate > $TIMEOUT) {
			$state = 'OFF';
		} elsif ($timeSinceUpdate < $TIMEOUT) {
			$state = 'MOTION';
		}
	}
	if ($state eq 'INIT') {
		$state = 'OFF';
	}

	# Update the lighting state
	if ($stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State: ' . $stateLast . ' => ' . $state . "\n";
			foreach my $data (@{ $DIM{$state} }) {
				print STDERR "\t" . $data->{'channel'} . ' => ' . $data->{'value'} . ' @ ' . $data->{'time'} . "\n";
			}
		}

		# Send the dim command
		my @values = ();
		foreach my $data (@{ $DIM{$state} }) {
			dim($data->{'channel'}, $data->{'time'}, $data->{'value'});
			push(@values, $data->{'channel'} . ' => ' . $data->{'value'} . ' @ ' . $data->{'time'});
		}

		# Save the state and value to disk
		my ($fh, $tmp) = tempfile($DATA_DIR . 'ROPE.XXXXXXXX', 'UNLINK' => 0);
		print $fh 'State: ' . $state . "\n" . join("\n", @values) . "\n";
		close($fh);
		rename($tmp, $DATA_DIR . 'ROPE');
	}

	# Wait and loop
	usleep($DELAY);
}

sub mtime($) {
	my ($file) = @_;
	my $mtime = 0;
	if (-r $file) {
		(undef(), undef(), undef(), undef(), undef(), undef(), undef(), undef(), undef(), $mtime, undef(), undef(), undef()) = stat($file);
	}
	return $mtime;
}

# Send the command
sub dim($$$) {
	my ($channel, $duration, $intensity) = @_;
	my $cmd = join(':', $channel, $duration, $intensity);
	$sock->send($cmd)
	  or die('Unable to write command to socket: ' . $CMD_FILE . ': ' . $cmd . ": ${!}\n");
}
