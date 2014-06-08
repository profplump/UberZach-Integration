#!/usr/bin/perl
use strict;
use warnings;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'ANNOUNCE';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# State
my %exists    = ();
my %last      = ();
my $pullLast  = time();

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;
	%last = %exists;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, undef(), undef());
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Speak when BRIGHT changes
	if (exists($exists{'BRIGHT'}) && exists($last{'BRIGHT'}) && $exists{'BRIGHT'} ne $last{'BRIGHT'}) {
		if ($exists{'BRIGHT'}) {
			DMX::say('Lights - Full power');
		} else {
			DMX::say('Lights - Nominal power');
		}
	}

	# Speak when LIGHTS changes
	if (exists($exists{'LIGHTS'}) && exists($last{'LIGHTS'}) && $exists{'LIGHTS'} ne $last{'LIGHTS'}) {
		if ($exists{'LIGHTS'}) {
			DMX::say('Lights up');
		} else {
			DMX::say('Lights down');
		}
	}

	# Speak when NO_MOTION changes
	if (exists($exists{'NO_MOTION'}) && exists($last{'NO_MOTION'}) && $exists{'NO_MOTION'} ne $last{'NO_MOTION'}) {
		if ($exists{'NO_MOTION'}) {
			DMX::say('Motion detectors: Disabled');
		} else {
			DMX::say('Motion detectors: Enabled');
		}
	}
}
