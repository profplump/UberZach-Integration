#!/usr/bin/perl
use strict;
use warnings;
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
my $DATA_DIR     = $TEMP_DIR . 'plexMonitor/';
my $DMX_SOCK     = $DATA_DIR . 'DMX.socket';
my $SUB_SOCK     = $DATA_DIR . 'STATE.socket';

# DMX socket init
sub dmxSock() {
	my $dmx_fh = IO::Socket::UNIX->new(
	        'Peer'    => $DMX_SOCK,
	        'Type'    => IO::Socket::UNIX::SOCK_DGRAM,
	        'Timeout' => $SOCK_TIMEOUT
	) or die('Unable to open socket: ' . $DMX_SOCK . ": ${@}\n");
	return $dmx_fh;
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
	        'Type'  => IO::Socket::UNIX::SOCK_DGRAM
	) or die('Unable to open state client socket: ' . $STATE_SOCK . ": ${@}\n");

	my $select = IO::Select->new($state_fh)
	  or die('Unable to select state client socket: ' . $STATE_SOCK . ": ${!}\n");
	return $select;
}

# Parse the state->client comm string
sub parseState($$) {
	my ($fh, $exists) = @_;

	# Grab the inbound text
	my $text = undef();
	$fh->recv($text, $MAX_CMD_LEN);

	# Parse the string
	my %tmp = ();
	%{$exists} = ();
	my ($cmdState, $exists_text) = $text =~ /^(\w+)(?:\s+\(([^\)]+)\))?/;
	if (!defined($cmdState)) {
		print STDERR 'State parse error: ' . $text . "\n";
		next;
	}
	if (defined($exists_text)) {
		foreach my $exists_val (split(/\s*,\s*/, $exists_text)) {
			my ($name, $value) = $exists_val =~ /(\w+)\:(0|1)/;
			if (!defined($name) || !defined($value)) {
				print STDERR 'State parse error (exists): ' . $text . "\n";
				next;
			}
			$exists->{$name} = $value;
		}
	}
	if ($DEBUG) {
		my @exists_tmp = ();
		foreach my $key (keys(%{ $exists })) {
			push(@exists_tmp, $key . ':' . $exists->{$key});
		}
		print STDERR 'Got state: ' . $cmdState . ' (' . join(', ', @exists_tmp) . ")\n";
	}


	# Translate INIT to OFF
	if ($cmdState eq 'INIT') {
		$cmdState = 'OFF';
	}

	# Return the state
	return $cmdState;
}

# Always return true
1;
