#!/usr/bin/perl
use strict;
use warnings;

# Local modules
use Cwd qw( abs_path );
use File::Temp qw( tempfile );
use File::Basename qw( dirname );
use lib dirname(abs_path($0));
use DMX;

# Config
my $TIMEOUT     = 900;
my $COUNTDOWN   = 119;
my $OFF_DELAY   = 15;
my $CMD_DELAY   = 20;
my $PAUSE_DELAY = 10;

# Available color modes, bright to dark:
#	DYNAMIC
#	NATURAL
#	THEATER
#	THEATER_BLACK_1
#
# Color modes by proportion of lamp life
my $LAMP_LIFE = 1625;
my %COLORS    = (
	'0.332' => {
		'high' => 'THEATER',
		'play' => 'THEATER_BLACK_1',
		'low'  => 'THEATER_BLACK_1',
	},
	'0.600' => {
		'high' => 'NATURAL',
		'play' => 'THEATER',
		'low'  => 'THEATER_BLACK_1',
	},
	'0.700' => {
		'high' => 'DYNAMIC',
		'play' => 'NATURAL',
		'low'  => 'THEATER_BLACK_1',
	},
	'0.800' => {
		'high' => 'DYNAMIC',
		'play' => 'DYNAMIC',
		'low'  => 'THEATER_BLACK_1',
	},
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'PROJECTOR_CTRL';
my $PROJ_SOCK    = 'PROJECTOR';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $POWER_FILE   = $OUTPUT_FILE . '_POWER';
my $LIFE_FILE    = $OUTPUT_FILE . '_LIFE';
my $TIMER_FILE   = $OUTPUT_FILE . '_TIMER';
my $COLOR_FILE   = $OUTPUT_FILE . '_COLOR';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);
my $proj = DMX::clientSock($PROJ_SOCK);

# State
my $state        = 'OFF';
my $stateLast    = $state;
my %exists       = ();
my %mtime        = ();
my $pullLast     = time();
my $lastAnnounce = 0;
my $lastUser     = time();
my $shutdown     = 0;
my $life         = 0;
my $lifeLast     = 0;
my @color_sets   = sort { $a <=> $b } keys(%COLORS);
my $color_set    = $color_sets[0];
my $color        = $COLORS{$color_set}{'low'};
my $lastPlay     = 0;
my $timeLeft     = 0;
my $timeLeftLast = 0;
my $colorCmd     = undef();
my $colorLast    = 0;
my $powerCmd     = undef();
my $powerLast    = 0;

# Loop forever
while (1) {

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, \%mtime, undef());

	# Avoid repeated calls to time()
	my $now = time();

	# Record only valid states
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = $now;
	}

	# Die if we don't see regular updates
	if ($now - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Menu changes count as activity
	if ($mtime{'GUI'} && $lastUser < $mtime{'GUI'}) {
		$lastUser = $mtime{'GUI'};
	}

	# Projector starts count as activity
	if ($exists{'PROJECTOR'} && $lastUser < $mtime{'PROJECTOR'}) {
		$lastUser = $mtime{'PROJECTOR'};
	} elsif ($newState eq 'ON') {
		$lastUser = $now;
	}

	# Playing counts as activity
	if ($exists{'PLAYING'} && $lastUser < $now) {
		$lastUser = $now;
	}

	# Motion counts as activity
	if ($mtime{'MOTION'} > $lastUser) {
		$lastUser = $mtime{'MOTION'};
	}

	# Motion counts as activity when PLEX is not active
	if (!$exists{'PLEX'} && $mtime{'MOTION'} > $lastUser) {
		$lastUser = $mtime{'MOTION'};
	}

	# Explict no-motion counts as activity when Plex is not foreground
	if (!$exists{'PLEX'} && $exists{'NO_MOTION'} && $lastUser < $now) {
		$lastUser = $now;
	}

	# Clear the shutdown timestamp if there is new user activity
	if ($shutdown && (!$exists{'PROJECTOR'} || $lastUser > $shutdown)) {
		$shutdown = 0;
	}

	# Record the shutdown timestamp, if the projector is on
	if ($newState eq 'SHUTDOWN' && $exists{'PROJECTOR'}) {
		if ($DEBUG) {
			print STDERR "Recorded shutdown timestamp\n";
		}
		$shutdown = $now;
		$lastUser = $now;
	}

	# Calculate the elapsed time
	my $elapsed = $now - $lastUser;
	if ($DEBUG) {
		print STDERR 'Time since last user action: ' . $elapsed . "\n";
	}

	# Calculate the new state
	if ($exists{'PROJECTOR'}) {
		if ($shutdown) {
			$state = 'SHUTDOWN';
			if ($elapsed > $OFF_DELAY) {
				$state = 'OFF';
			}
		} else {
			if ($elapsed > $TIMEOUT) {
				$state = 'COUNTDOWN';
				if ($elapsed > $TIMEOUT + $COUNTDOWN) {
					$state = 'OFF';
				}
			} else {
				$state = 'ON';
			}
		}
	} else {
		if ($newState eq 'ON') {
			$state = 'ON';
		}
	}

	# Select a color set based on the lamp life
	if (exists($exists{'PROJECTOR_LAMP'})) {
		$life = $exists{'PROJECTOR_LAMP'} / $LAMP_LIFE;
		if ($DEBUG) {
			print STDERR 'Lamp life: ' . ($life * 100) . "%\n";
		}
		my $max_set_num = scalar(@color_sets) - 1;
		$color_set = $color_sets[$max_set_num];
		for (my $i = 0 ; $i < $max_set_num ; $i++) {
			if ($life < $color_sets[$i]) {
				$color_set = $color_sets[$i];
				last;
			}
		}
		if ($DEBUG) {
			print STDERR 'Color set: ' . $color_set . "\n";
		}
	}

	# Calculate the color mode
	# PLAY for normal playback
	# HIGH when playing and LIGHTS || BRIGHT
	# LOW for audio, and when we're half way to the timeout (to save the bulb)
	# HIGH when the GUI is up
	# PLAY if we haven't figured out what else to do
	my $playLights = 0;
	if ($newState eq 'PLAY') {
		$lastPlay   = $now;
		$playLights = 1;
	} elsif ($newState eq 'PAUSE' && $lastPlay + $PAUSE_DELAY > $now) {
		$playLights = 1;
	} elsif ($exists{'PLAYING_TYPE'} eq 'audio') {
		$color = $COLORS{$color_set}{'low'};
	} elsif ($elapsed > $TIMEOUT / 2) {
		$color = $COLORS{$color_set}{'low'};
	} elsif ($exists{'GUI'}) {
		$color = $COLORS{$color_set}{'high'};
	} else {
		$playLights = 1;
	}

	# If playLights was set, choose the color mode based on the LIGHTS setting
	if ($playLights) {
		$color = $COLORS{$color_set}{'play'};
		if ($exists{'LIGHTS'} || $exists{'BRIGHT'}) {
			$color = $COLORS{$color_set}{'high'};
		}
	}
	if ($DEBUG) {
		print STDERR 'Selected color: ' . $color . "\n";
	}

	# Calculate the shutdown counter
	$timeLeft = 0;
	if ($state eq 'SHUTDOWN') {
		$timeLeft = $OFF_DELAY - $elapsed;
	} elsif ($state eq 'COUNTDOWN') {
		$timeLeft = ($TIMEOUT + $COUNTDOWN) - $elapsed;
	}

	# Update power when there is a state mismatch
	if (($state eq 'OFF' && $exists{'PROJECTOR'}) || ($state eq 'ON' && !$exists{'PROJECTOR'})) {
		if ($DEBUG) {
			print STDERR 'Power state mismatch: ' . $state . ':' . $exists{'PROJECTOR'} . "\n";
		}
		$powerCmd = $state;
	}

	# Update color when there is a state mismatch and the projector is on
	if ($exists{'PROJECTOR'} && $exists{'PROJECTOR_COLOR'} ne $color) {
		if ($DEBUG) {
			print STDERR 'Color state mismatch: ' . $color . ':' . $exists{'PROJECTOR_COLOR'} . "\n";
		}
		$colorCmd = $color;
	}

	# Save the power state to disk
	if ($state ne $stateLast) {
		my ($fh, $tmp) = tempfile($POWER_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $state . "\n";
		close($fh);
		rename($tmp, $POWER_FILE);
		$stateLast = $state;
	}

	# Save the color state to disk
	if ($color ne $colorLast) {
		my ($fh, $tmp) = tempfile($COLOR_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $color . "\n";
		close($fh);
		rename($tmp, $COLOR_FILE);
		$colorLast = $color;
	}

	# Save the lamp life to disk
	if ($life != $lifeLast) {
		my ($fh, $tmp) = tempfile($LIFE_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $life . "\n";
		close($fh);
		rename($tmp, $LIFE_FILE);
		$lifeLast = $life;
	}

	# Save the shutdown time to disk
	if ($timeLeft != $timeLeftLast) {
		my ($fh, $tmp) = tempfile($TIMER_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $timeLeft . "\n";
		close($fh);
		rename($tmp, $TIMER_FILE);
		$timeLeftLast = $timeLeft;
	}

	# Send the color mode, if requested
	if ($colorCmd) {
		if ($DEBUG) {
			print STDERR 'Setting color mode: ' . $color . "\n";
		}
		$proj->send($color)
		  or die('Unable to write command to projector socket: ' . $color . ": ${!}\n");
		$colorCmd = undef();
	}

	# Send master power state, if requested
	# Only allow updates every few seconds -- the projector goes dumb during power state changes
	if ($powerCmd && $now > $powerLast + $CMD_DELAY) {
		if ($DEBUG) {
			print STDERR 'Setting power state: ' . $state . "\n";
		}

		$proj->send($state)
		  or die('Unable to write command to proj socket: ' . $state . ": ${!}\n");
		$powerLast = $now;
		$powerCmd  = undef();
	}
}
