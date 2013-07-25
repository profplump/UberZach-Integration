#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::UNIX;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# App config
my $DATA_DIR = DMX::dataDir();

# Command-line parameters
my ($DEV, $CMD) = @ARGV;
my $CMD_FILE = uc($DEV);

# Socket init
my $sock = DMX::clientSock($CMD_FILE);

# Send the command
$sock->send($CMD)
  or die('Unable to write command to socket: ' . $CMD_FILE . ': ' . $CMD . ": ${!}\n");

# Cleanup
$sock->close();
undef($sock);
exit(0);
