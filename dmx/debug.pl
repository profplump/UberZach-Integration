#!/usr/bin/perl
use strict;
use warnings;

# Always debug
BEGIN { $ENV{'DEBUG'} = 1; }

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# User config
my %DIM   = ();
my $DELAY = 10;

# App config
my $DATA_DIR   = DMX::dataDir();
my $STATE_SOCK = $DATA_DIR . 'DEBUG.socket';

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# Loop forever
my %exists = ();
my %mtime  = ();
while (1) {
	my $state = DMX::readState($DELAY, \%exists, \%mtime, undef());

	if ($state) {
		my $file = undef();
		foreach my $key (keys(%mtime)) {
			if (!defined($file) || $mtime{$key} > $mtime{$file}) {
				$file = $key;
			}
		}
		print STDERR "\tLast update: " . $file . ': ' . localtime($mtime{$file}) . "\n";
	}
}
