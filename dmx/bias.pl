#!/usr/bin/perl
use strict;
use warnings;
use IO::Select;
use IO::Socket::UNIX;
use File::Temp qw( tempfile );

# Prototypes
sub dim($);

# User config
my %DIM = (
	'OFF'    => [
		# Handled by rope.pl
	],
	'PLAY'   => [
		{ 'channel' => 12, 'value' => 255, 'time' => 0 }
	],
	'PAUSE'   => [
		{ 'channel' => 12, 'value' => 0,  'time' => 0, 'delay' => 8000 }
	],
	'MOTION'  => [
		{ 'channel' => 12, 'value' => 0,  'time' => 0 }
	],
);

# App config
my $SOCK_TIMEOUT = 5;
my $TEMP_DIR     = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR     = $TEMP_DIR . 'plexMonitor/';
my $DMX_SOCK     = $DATA_DIR . 'DMX.socket';
my $SUB_SOCK     = $DATA_DIR . 'STATE.socket';
my $STATE_SOCK   = $DATA_DIR . 'ROPE.socket';
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
	$DELAY = $PULL_TIMEOUT / 2;
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
my $state     = 'INIT';
my $stateLast = $state;
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();

# Always force lights out at launch
dim({ 'channel' => 12, 'value' => 0, 'time' => 0 });

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
		my $text = undef();
		$fh->recv($text, $MAX_CMD_LEN);

		# Parse the string
		%exists = ();
		my ($cmdState, $exists_text) = $text =~ /^(\w+)\s+\(([^\)]+)\)/;
		if (!defined($cmdState) || !defined($exists_text)) {
			print STDERR 'State parse error: ' . $text . "\n";
			next;
		}
		foreach my $exists (split(/\s*,\s*/, $exists_text)) {
			my ($name, $value) = $exists =~ /(\w+)\:(0|1)/;
			if (!defined($name) || !defined($value)) {
				print STDERR 'State parse error (exists): ' . $text . "\n";
				next;
			}
			$exists{$name} = $value;
		}
		if ($DEBUG) {
			my @exists_tmp = ();
			foreach my $key (keys(%exists)) {
				push(@exists_tmp, $key . ':' . $exists{$key});
			}
			print STDERR 'Got state: ' . $cmdState . ' (' . join(', ', @exists_tmp) . ")\n";
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

	# Accept the new state directly
	$stateLast = $state;
	$state     = $newState;

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
		my ($fh, $tmp) = tempfile($DATA_DIR . 'BIAS.XXXXXXXX', 'UNLINK' => 0);
		print $fh 'State: ' . $state . "\n" . join("\n", @values) . "\n";
		close($fh);
		rename($tmp, $DATA_DIR . 'BIAS');

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
	  or die('Unable to write command to socket: ' . $DMX_SOCK . ': ' . $cmd . ": ${!}\n");
}
