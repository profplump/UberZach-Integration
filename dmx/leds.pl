#!/usr/bin/perl
use strict;
use warnings;
use IO::Select;
use IO::Socket::UNIX;
use File::Temp qw( tempfile );

# Prototypes
sub dim($);
sub red_alert();
sub red_flash();

# Effects states
my %EFFECTS = (
	'RED_ALERT' => \&red_alert,
	'RED_FLASH' => \&red_flash,
);

# User config
my %DIM = (
	'OFF'    => [
		# Handled by rope.pl
	],
	'PLAY'      => [
		{ 'channel' => 13, 'value' => 10,   'time' => 500  },
		{ 'channel' => 14, 'value' => 12,   'time' => 500  },
		{ 'channel' => 15, 'value' => 8,    'time' => 500  },
	],
	'PLAY_HIGH' => [
		{ 'channel' => 13, 'value' => 64,  'time' => 1000, 'delay' => 3000 },
		{ 'channel' => 14, 'value' => 73,  'time' => 1000, 'delay' => 1500 },
		{ 'channel' => 15, 'value' => 76,  'time' => 1000, 'delay' => 0    },
	],
	'PAUSE'     => [
		{ 'channel' => 13, 'value' => 96,  'time' => 3000, 'delay' => 3000 },
		{ 'channel' => 14, 'value' => 109, 'time' => 3000, 'delay' => 0    },
		{ 'channel' => 15, 'value' => 114, 'time' => 3000, 'delay' => 7000 },
	],
	'MOTION'    => [
		{ 'channel' => 13, 'value' => 144, 'time' => 1000  },
		{ 'channel' => 14, 'value' => 164, 'time' => 1000  },
		{ 'channel' => 15, 'value' => 172, 'time' => 1000  },
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
my $state      = 'INIT';
my $stateLast  = $state;
my %exists     = ();
my %existsLast = %exists;
my $pushLast   = 0;
my $pullLast   = time();

# Always force lights out at launch
dim({ 'channel' => 13, 'value' => 0, 'time' => 0 });
dim({ 'channel' => 14, 'value' => 0, 'time' => 0 });
dim({ 'channel' => 15, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# Record the last state/exists data for diffs/resets
	$stateLast  = $state;
	%existsLast = %exists;

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
		if (!defined($DIM{$cmdState}) && !defined($EFFECTS{$cmdState})) {
			print STDERR 'Invalid state: ' . $cmdState . "\n";
			next;
		}

		# Propogate the most recent command state
		$newState = $cmdState;
		$pullLast = time();
	}

	# Special handling for effects states
	if (defined($EFFECTS{$newState})) {

		# Dispatch the handler
		$EFFECTS{$newState}->();

		# Force an update back to the original state
		$newState    = $stateLast;
		%exists      = %existsLast;
		$forceUpdate = 1;
	}

	# Calculate the new state
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
	if (time() - $pullLast > $PUSH_TIMEOUT) {
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

# ======================================
# Effects routines
# These are blocking, so be careful
# ======================================
sub red_alert() {

}

sub red_flash() {

}
