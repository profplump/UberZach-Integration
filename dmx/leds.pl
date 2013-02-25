#!/usr/bin/perl
use strict;
use warnings;
use IO::Select;
use IO::Socket::UNIX;
use File::Temp qw( tempfile );

# Prototypes
sub mtime($);
sub dim($);

# User config
my %DIM = (
	'OFF'    => [
		# Handled by rope.pl
	],
	'PLAY'      => [
		{ 'channel' => 13, 'value' => 4,    'time' => 250  },
		{ 'channel' => 14, 'value' => 4,    'time' => 250  },
		{ 'channel' => 15, 'value' => 4,    'time' => 250  },
	],
	'PLAY_HIGH' => [
		{ 'channel' => 13, 'value' => 8,   'time' => 500,  'delay' => 0    },
		{ 'channel' => 14, 'value' => 8,   'time' => 500,  'delay' => 250  },
		{ 'channel' => 15, 'value' => 8,   'time' => 500,  'delay' => 500  },
	],
	'PAUSE'     => [
		{ 'channel' => 13, 'value' => 16,  'time' => 1000, 'delay' => 9000 },
		{ 'channel' => 14, 'value' => 16,  'time' => 1000, 'delay' => 6000 },
		{ 'channel' => 15, 'value' => 16,  'time' => 1000, 'delay' => 3000 },
	],
	'MOTION'    => [
		{ 'channel' => 13, 'value' => 32,  'time' => 1000  },
		{ 'channel' => 14, 'value' => 32,  'time' => 1000  },
		{ 'channel' => 15, 'value' => 32,  'time' => 1000  },
	],
);

# App config
my $SOCK_TIMEOUT = 5;
my $TEMP_DIR     = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR     = $TEMP_DIR . 'plexMonitor/';
my $DMX_SOCK     = $DATA_DIR . 'DMX.socket';
my $SUB_SOCK     = $DATA_DIR . 'STATE.socket';
my $STATE_SOCK   = $DATA_DIR . 'LED.socket';
my $MAX_CMD_LEN  = 1024;
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
	$DELAY = 0.5;
}

# Sanity check
if (!-d $DATA_DIR || !-S $DMX_SOCK || !-S $SUB_SOCK) {
	die("Bad config\n");
}

# State socket init
if (-e $STATE_SOCK) {
	unlink($STATE_SOCK);
}
my $state_fh = IO::Socket::UNIX->new(
	'Local' => $STATE_SOCK,
	'Type'  => SOCK_DGRAM
) or die('Unable to open socket: ' . $STATE_SOCK . ": ${@}\n");
my $select = IO::Select->new($state_fh)
  or die('Unable to select socket: ' . $STATE_SOCK . ": ${!}\n");

# DMX socket init
my $dmx_fh = IO::Socket::UNIX->new(
	'Peer'    => $DMX_SOCK,
	'Type'    => SOCK_DGRAM,
	'Timeout' => $SOCK_TIMEOUT
) or die('Unable to open socket: ' . $DMX_SOCK . ": ${@}\n");

# Subscribe to state updates
my $sub_fh = IO::Socket::UNIX->new(
	'Peer'    => $SUB_SOCK,
	'Type'    => SOCK_DGRAM,
	'Timeout' => $SOCK_TIMEOUT
) or die('Unable to open socket: ' . $SUB_SOCK . ": ${@}\n");
$sub_fh->send($STATE_SOCK)
  or die('Unable to subscribe: ' . $! . "\n");
shutdown($sub_fh, 2);
undef($sub_fh);

# State
my $state      = 'INIT';
my $stateLast  = $state;
my $lights     = 0;
my $updateLast = 0;
my $pushLast   = 0;
my $pullLast   = time();

# Always force lights out at launch
dim({ 'channel' => 13, 'value' => 0, 'time' => 0 });
dim({ 'channel' => 14, 'value' => 0, 'time' => 0 });
dim({ 'channel' => 15, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {
	
	# Set anywhere to force an update this cycle
	my $forceUpdate = 0;

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my @ready_clients = $select->can_read($DELAY);
	foreach my $fh (@ready_clients) {

		# Grab the inbound text
		my $cmdState = undef();
		$fh->recv($cmdState, $MAX_CMD_LEN);
		$cmdState =~ s/^\s+//;
		$cmdState =~ s/\s+$//;
		if ($DEBUG) {
			print STDERR 'Got state: ' . $cmdState . "\n";
		}

		# Translate INIT to OFF
		if ($cmdState eq 'INIT') {
			$cmdState = 'OFF';
		}

		# Only accept valid states
		if (!defined($DIM{$cmdState})) {
			print STDERR 'Invalid state: ' . $cmdState . "\n";
			next;
		}

		# Propogate the most recent command state
		$newState = $cmdState;
		$pullLast = time();
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

		# Clear the override when the main state is "OFF"
		if ($lights && $newState eq 'OFF') {
			unlink($DATA_DIR . 'LIGHTS');
		}
	}

	# Calculate the new state
	$stateLast = $state;
	if ($lights) {
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
	if (time() - $pullLast > $PUSH_TIMEOUT) {
		$forceUpdate = 1;
	}
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Update the lighting
	if ($forceUpdate || $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State: ' . $stateLast . ' => ' . $state . "\n";
			foreach my $data (@{ $DIM{$state} }) {
				print STDERR "\t" . $data->{'channel'} . ' => ' . $data->{'value'} . ' @ ' . $data->{'time'} . "\n";
			}
		}

		# Send the dim command
		my @values = ();
		foreach my $data (@{ $DIM{$state} }) {
			dim($data);
			push(@values, $data->{'channel'} . ' => ' . $data->{'value'} . ' @ ' . $data->{'time'});
		}

		# Save the state and value to disk
		my ($fh, $tmp) = tempfile($DATA_DIR . 'LED.XXXXXXXX', 'UNLINK' => 0);
		print $fh 'State: ' . $state . "\n" . join("\n", @values) . "\n";
		close($fh);
		rename($tmp, $DATA_DIR . 'LED');
		
		# Update the push time
		$pushLast = time();
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
	  or die('Unable to write command to socket: ' . $DMX_SOCK . ': ' . $cmd . ": ${!}\n");
}
