#!/usr/bin/perl
use strict;
use warnings;

# Local modules
use POSIX;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# User config
my %DIM   = ();
my $DELAY = 10;

# App config
my $STATE_SOCK = 'DEBUG';

# Allow one-shot mode or force debug
my $KEY = undef();
if (scalar(@ARGV) > 0) {
	$KEY = $ARGV[0];
} else {
	DMX::debug(1);
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# Loop forever
my %exists = ();
my %mtime  = ();
while (1) {
	my $state = DMX::readState($DELAY, \%exists, \%mtime, undef());

	if ($state) {

		# One-shot mode
		if (defined($KEY)) {
			if (exists($exists{$KEY})) {
				print $KEY . ' => ' . $exists{$KEY} . ' @ ' .
				  POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime($mtime{$KEY})) . "\n";
			} else {
				print STDERR 'No such element: ' . $KEY . "\n";
			}
			exit 0;
		}

		# Find the latest modification timestamp
		my $file = undef();
		foreach my $key (keys(%mtime)) {
			if (!defined($file) || $mtime{$key} > $mtime{$file}) {
				$file = $key;
			}
		}

		# Pretty print
		my $time = 0;
		if (defined($file)) {
			$time = $mtime{$file};
		} else {
			$file = '<NO MTIME DATA>';
		}
		print STDERR "\tLast update: " . $file . ': ' . localtime($time) . "\n";
	}
}
