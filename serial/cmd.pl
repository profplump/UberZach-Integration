#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::UNIX;
use POSIX qw(ceil floor);

# App config
my $TIMEOUT  = 5;
my $TEMP_DIR = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR = $TEMP_DIR . 'plexMonitor/';

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Command-line parameters
my ($DEV, $CMD) = @ARGV;
my $CMD_FILE = $DATA_DIR . uc($DEV) . '.socket';

# Sanity check
if (!-d $DATA_DIR || !-S $CMD_FILE) {
	die("Bad config\n");
}

# Socket init
my $sock = IO::Socket::UNIX->new(
	'Peer'    => $CMD_FILE,
	'Type'    => SOCK_DGRAM,
	'Timeout' => $TIMEOUT
) or die('Unable to open socket: ' . $CMD_FILE . ": ${@}\n");

# Send the command
$sock->send($CMD)
  or die('Unable to write command to socket: ' . $CMD_FILE . ': ' . $CMD . ": ${!}\n");

# Cleanup
$sock->close();
undef($sock);
exit(0);
