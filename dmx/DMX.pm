#!/usr/bin/perl
use strict;
use warnings;
use File::Temp;
use IO::Select;
use IO::Socket::UNIX;

# Package name
package DMX;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Config
my $SOCK_TIMEOUT = 5;
my $MAX_CMD_LEN  = 1024;
my $TEMP_DIR     = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR    = $TEMP_DIR . 'plexMonitor/';
my $DMX_SOCK    = $DATA_DIR . 'DMX.socket';
my $SUB_SOCK    = $DATA_DIR . 'STATE.socket';
my %CHANNEL_ADJ = (
	'13' => 1.00,
	'14' => 1.14,
	'15' => 1.19,
);

# Sanity check
if (!-d $DATA_DIR) {
	die('Data directory not available: ' . $DATA_DIR . "\n");
}

# State
my $DMX_FH = undef();
my $SELECT = undef();

# Data directory
sub dataDir() {
	return $DATA_DIR;
}

# Generic client socket
sub clientSock($) {
	my ($path) = @_;
	my $sock = IO::Socket::UNIX->new(
		'Peer'    => $path,
		'Type'    => IO::Socket::UNIX::SOCK_DGRAM,
		'Timeout' => $SOCK_TIMEOUT,
	) or die('Unable to open client socket: ' . $path . ": ${@}\n");
	return $sock;
}

# DMX socket init
sub dmxSock() {
	if (!defined($DMX_FH)) {
		$DMX_FH = clientSock($DMX_SOCK);
	}
	return $DMX_FH;
}

# Subscribe to state updates
sub stateSubscribe($) {
	my ($STATE_SOCK) = @_;

	my $sub_fh = IO::Socket::UNIX->new(
		'Peer'    => $SUB_SOCK,
		'Type'    => IO::Socket::UNIX::SOCK_DGRAM,
		'Timeout' => $SOCK_TIMEOUT
	) or die('Unable to open state subscription socket: ' . $SUB_SOCK . ": ${@}\n");
	$sub_fh->send($STATE_SOCK)
	  or die('Unable to subscribe: ' . $! . "\n");
	shutdown($sub_fh, 2);
	undef($sub_fh);
}

# State client socket init
sub stateSocket($) {
	my ($STATE_SOCK) = @_;

	if (-e $STATE_SOCK) {
		unlink($STATE_SOCK);
	}
	my $state_fh = IO::Socket::UNIX->new(
		'Local' => $STATE_SOCK,
		'Type'  => IO::Socket::UNIX::SOCK_DGRAM,
	) or die('Unable to open state client socket: ' . $STATE_SOCK . ": ${@}\n");

	$SELECT = IO::Select->new($state_fh)
	  or die('Unable to select state client socket: ' . $STATE_SOCK . ": ${!}\n");
	return $SELECT;
}

# Parse the state->client comm string
sub parseState($$) {
	my ($text, $exists) = @_;
	my $cmdState    = undef();
	my $exists_text = undef();

	# Parse the string
	my %tmp = ();
	%{$exists} = ();
	($cmdState, $exists_text) = $text =~ /^(\w+)(?:\s+\(([^\)]+)\))?/;
	if (!defined($cmdState)) {
		print STDERR 'State parse error: ' . $text . "\n";
		next;
	}
	if (defined($exists_text)) {
		foreach my $exists_val (split(/\s*,\s*/, $exists_text)) {
			my ($name, $value) = $exists_val =~ /(\w+)\:(\d+)/;
			if (!defined($name) || !defined($value)) {
				print STDERR 'State parse error (exists): ' . $text . "\n";
				next;
			}
			$exists->{$name} = $value;
		}
	}
	if ($DEBUG) {
		my @exists_tmp = ();
		foreach my $key (keys(%{$exists})) {
			push(@exists_tmp, $key . ':' . $exists->{$key});
		}
		print STDERR 'Got state: ' . $cmdState . ' (' . join(', ', @exists_tmp) . ")\n";
	}

	# Translate INIT to OFF
	if ($cmdState eq 'INIT') {
		$cmdState = 'OFF';
	}

	# Return
	return $cmdState;
}

sub dim($) {
	my ($args) = @_;
	if (!defined($args->{'delay'})) {
		$args->{'delay'} = 0;
	}
	if (!defined($args->{'channel'}) || !defined($args->{'time'}) || !defined($args->{'value'})) {
		die('Invalid command for socket: ' . join(', ', keys(%{$args})) . ': ' . join(', ', values(%{$args})) . "\n");
	}

	# Silently skip invalid channels
	if ($args->{'channel'} < 0) {
		return;
	}

	# Adjust for the color curve (for channels where we have such data)
	my $value = $args->{'value'};
	if ($CHANNEL_ADJ{ $args->{'channel'} }) {
		$value *= $CHANNEL_ADJ{ $args->{'channel'} };
	}

	# 8-bit values
	$value = int($value);
	if ($value > 255) {
		$value = 255;
	} elsif ($value < 0) {
		$value = 0;
	}

	# We only deal in ints
	my $time  = int($args->{'time'});
	my $delay = int($args->{'delay'});

	my $cmd = join(':', $args->{'channel'}, $time, $value, $delay);

	dmxSock();
	$DMX_FH->send($cmd)
	  or die('Unable to write command to DMX socket: ' . $cmd . ": ${!}\n");
}

sub printDataset($) {
	my ($data_set) = @_;

	my $sum = 0;
	foreach my $data (@{$data_set}) {
		$sum += $data->{'value'};
		my $str = $data->{'channel'} . ' => ' . int($data->{'value'}) . ' @ ' . $data->{'time'};
		if ($data->{'delay'}) {
			$str .= ' (Delay: ' . $data->{'delay'} . ')';
		}
		print STDERR "\t" . $str . "\n";
	}
	print STDERR "\tTotal: " . int($sum) . "\n";
}

sub applyDataset($$$) {
	my ($data_set, $state, $file) = @_;
	if (!defined($state)) {
		$state = 'NULL';
	}

	# Debug
	if ($DEBUG) {
		print STDERR 'State: ' . $state . "\n";
		printDataset($data_set);
	}

	# Send the dim command
	my @values = ();
	foreach my $data (@{$data_set}) {
		dim($data);
		my $str = $data->{'channel'} . ' => ' . $data->{'value'} . ' @ ' . $data->{'time'};
		if ($data->{'delay'}) {
			$str .= ' (Delay: ' . $data->{'delay'} . ')';
		}
		push(@values, $str);
	}

	# Save the state and value to disk
	if (length($file)) {
		my ($fh, $tmp) = File::Temp::tempfile($file . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh 'State: ' . $state . "\n" . join("\n", @values) . "\n";
		close($fh);
		rename($tmp, $file);
	}
}

sub readState($$$) {
	my ($delay, $exists, $valid) = @_;
	my $cmdState = undef();

	# Wait for state updates
	my @ready_clients = $SELECT->can_read($delay);
	foreach my $fh (@ready_clients) {

		# Ensure we won't block on recv()
		$fh->blocking(0);

		# Grab the inbound text
		while (defined($fh->recv(my $text, $MAX_CMD_LEN))) {

			# Parse the string
			my $state = parseState($text, $exists);

			# Ignore invalid states
			if (defined($valid)) {
				if (!defined($valid->{$state})) {
					print STDERR 'Invalid state: ' . $state . "\n";
					next;
				}
			}

			# Propogate valid states
			if ($state) {
				$cmdState = $state;
			}
		}
	}

	# Return the final valid state
	return $cmdState;
}

# Always return true
1;
