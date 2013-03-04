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

# Prototypes
sub dim($);

# User config
my %DIM = (
	'OFF'    => [
		{ 'channel' => 0,  'value' => 0,   'time' => 60000 }
	],
	'PLAY'      => [
		{ 'channel' => 1,  'value' => 64,  'time' => 500   },
		{ 'channel' => 2,  'value' => 32,  'time' => 500   },
		{ 'channel' => 3,  'value' => 80,  'time' => 2500  },
		{ 'channel' => 5,  'value' => 64,  'time' => 500   },
		{ 'channel' => 6,  'value' => 36,  'time' => 500   },
		{ 'channel' => 7,  'value' => 32,  'time' => 500   },
		{ 'channel' => 8,  'value' => 16,  'time' => 500   },
		{ 'channel' => 9,  'value' => 16,  'time' => 500   },
	],
	'PLAY_HIGH' => [
		{ 'channel' => 1,  'value' => 255, 'time' => 500   },
		{ 'channel' => 2,  'value' => 128, 'time' => 500   },
		{ 'channel' => 3,  'value' => 192, 'time' => 1500  },
		{ 'channel' => 5,  'value' => 128, 'time' => 500   },
		{ 'channel' => 6,  'value' => 36,  'time' => 500   },
		{ 'channel' => 7,  'value' => 128, 'time' => 500   },
		{ 'channel' => 8,  'value' => 16,  'time' => 500   },
		{ 'channel' => 9,  'value' => 96,  'time' => 500   },
	],
	'PAUSE'     => [
		{ 'channel' => 1,  'value' => 255, 'time' => 1000  },
		{ 'channel' => 2,  'value' => 192, 'time' => 10000 },
		{ 'channel' => 3,  'value' => 192, 'time' => 5000  },
		{ 'channel' => 5,  'value' => 255, 'time' => 1000  },
		{ 'channel' => 6,  'value' => 104, 'time' => 6000, 'delay' => 3000 },
		{ 'channel' => 7,  'value' => 192, 'time' => 10000 },
		{ 'channel' => 8,  'value' => 96,  'time' => 6000, 'delay' => 6000 },
		{ 'channel' => 9,  'value' => 96,  'time' => 6000, 'delay' => 3000 },
	],
	'MOTION'    => [
		{ 'channel' => 1,  'value' => 255, 'time' => 1000  },
		{ 'channel' => 2,  'value' => 192, 'time' => 1000  },
		{ 'channel' => 3,  'value' => 192, 'time' => 1000  },
		{ 'channel' => 5,  'value' => 192, 'time' => 1000  },
		{ 'channel' => 6,  'value' => 104, 'time' => 1000  },
		{ 'channel' => 7,  'value' => 192, 'time' => 1000  },
		{ 'channel' => 8,  'value' => 96,  'time' => 2000  },
		{ 'channel' => 9,  'value' => 96,  'time' => 1500  },
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
dim({ 'channel' => 0, 'value' => 0, 'time' => 0 });

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

		# Only accept valid states
		if (!defined($DIM{$cmdState})) {
			print STDERR 'Invalid state: ' . $cmdState . "\n";
			next;
		}

		# Propogate the most recent command state
		$newState = $cmdState;
		$pullLast = time();
	}

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'LIGHTS'}) {
		if ($newState eq 'PLAY') {
			$newState = 'PLAY_HIGH';
		}
	} else {
		if ($newState eq 'PLAY_HIGH') {
			$newState = 'PLAY';
		}
	}
	$state = $newState;

	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		$forceUpdate = 1;
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Update the lighting
	if ($forceUpdate || $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State: ' . $stateLast . ' => ' . $state . "\n";
			foreach my $data (@{ $DIM{$state} }) {
				my $delay = '';
				if ($data->{'delay'}) {
					$delay = ' (Delay: ' . $data->{'delay'} . ')';
				}
				print STDERR "\t" . $data->{'channel'} . ' => ' . $data->{'value'} . ' @ ' . $data->{'time'} . $delay . "\n";
			}
		}

		# Send the dim command
		my @values = ();
		foreach my $data (@{ $DIM{$state} }) {
			dim($data);
			push(@values, $data->{'channel'} . ' => ' . $data->{'value'} . ' @ ' . $data->{'time'});
		}

		# Save the state and value to disk
		my ($fh, $tmp) = tempfile($DATA_DIR . 'ROPE.XXXXXXXX', 'UNLINK' => 0);
		print $fh 'State: ' . $state . "\n" . join("\n", @values) . "\n";
		close($fh);
		rename($tmp, $DATA_DIR . 'ROPE');

		# Update the push time
		$pushLast = time();
	}
}

# Send the command
sub dim($) {
	my ($args) = @_;
	if (!defined($args->{'delay'})) {
		$args->{'delay'} = 0;
	}
	if (!defined($args->{'channel'}) || !defined($args->{'time'}) || !defined($args->{'value'})) {
		die('Invalid command for socket: ' . join(', ', keys(%{$args})) . ': ' . join(', ', values(%{$args})) . "\n");
	}

	my $cmd = join(':', $args->{'channel'}, $args->{'time'}, $args->{'value'}, $args->{'delay'});
	$dmx_fh->send($cmd)
	  or die('Unable to write command to DMX socket: ' . $cmd . ": ${!}\n");
}
