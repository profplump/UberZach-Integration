#!/usr/bin/perl
use strict;
use warnings;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);
use File::Basename qw(dirname);
use Sys::Hostname;

# Local modules
use Cwd qw(abs_path);
use lib dirname(abs_path($0));
use DMX;

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'ANNOUNCE';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;
my $ALARM_DELAY  = 10;
my $MODE_DELAY   = 7.5;
my $PROJ_DELAY   = 59;
my $PROJ_FACTOR  = 0.95;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# State
my %exists    = ();
my %last      = ();
my %mtime     = ();
my $alarmLast = 0;
my $modeLast  = 0;
my $projLast  = 0;
my $pullLast  = time();

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# Loop forever
while (1) {

	# Remember the last state, for comparison
	%last = %exists;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, \%mtime, undef());

	# Avoid repeated calls to time()
	my $now = time();

	# Record only valid states
	if (defined($cmdState)) {
		$pullLast = $now;
	}

	# Die if we don't see regular updates
	if ($now - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Speak when the theater mode changes
	if (exists($exists{'GAME'}) && exists($last{'GAME'}) && $exists{'GAME'} ne $last{'GAME'}) {
		my $mode = 'PLEX';
		if ($exists{'GAME'}) {
			$mode = 'GAME';
		}

		# Wake the input system when we switch to it
		my $wol = $ENV{'HOME'} . '/bin/video/wol/wol-' . lc($mode) . '.sh';
		if (-x $wol) {
			system($wol);
		}

		# Allow other checks to opt-out if they are mode-switch related
		$modeLast = $now;

		DMX::say('Theater mode: ' . lc($mode));
	}

	# Speak when LIGHTS changes
	if (exists($exists{'LIGHTS'}) && exists($last{'LIGHTS'}) && $exists{'LIGHTS'} ne $last{'LIGHTS'}) {
		if ($now - $modeLast > $MODE_DELAY) {
			my $mode = 'DOWN';
			if ($exists{'LIGHTS'}) {
				$mode = 'UP';
			}

			DMX::say('Lights ' . lc($mode));
		}
	}

	# Speak when AMPLIFIER_INPUT changes
	if (   exists($exists{'AMPLIFIER_INPUT'})
		&& exists($last{'AMPLIFIER_INPUT'})
		&& $exists{'AMPLIFIER_INPUT'} ne $last{'AMPLIFIER_INPUT'})
	{
		if ($now - $modeLast > $MODE_DELAY) {
			DMX::say('Amplifier input: ' . lc($exists{'AMPLIFIER_INPUT'}));
		}
	}

	# Speak when AMPLIFIER_MODE changes
	if (   exists($exists{'AMPLIFIER_MODE'})
		&& exists($last{'AMPLIFIER_MODE'})
		&& $exists{'AMPLIFIER_MODE'} ne $last{'AMPLIFIER_MODE'})
	{
		DMX::say('Amplifier mode: ' . lc($exists{'AMPLIFIER_MODE'}));
	}

	# Speak when PROJECTOR_CTRL_TIMER changes
	if (exists($exists{'PROJECTOR_CTRL_TIMER'}) && $exists{'PROJECTOR_CTRL_TIMER'}) {
		if ($now - $projLast > $PROJ_DELAY) {

			# Determine the unit
			my $unit     = 'second';
			my $timeLeft = $exists{'PROJECTOR_CTRL_TIMER'};
			if ($exists{'PROJECTOR_CTRL_TIMER'} > 60) {
				$timeLeft = $exists{'PROJECTOR_CTRL_TIMER'} / 60;
				$unit     = 'minute';
			}

			# Avoid saying "0" unless we *really* mean it
			$timeLeft = ceil($timeLeft);

			# Add an "s" as needed
			my $plural = 's';
			if ($timeLeft == 1) {
				$plural = '';
			}
			$unit .= $plural;

			# Speak
			DMX::say('Projector shutdown in about ' . $timeLeft . ' ' . $unit);

			# Update the delay timer
			$projLast = $now;
		}
	}

	# Speak when PROJECTOR_CTRL_POWER changes
	if (   exists($exists{'PROJECTOR_CTRL_POWER'})
		&& exists($last{'PROJECTOR_CTRL_POWER'})
		&& $exists{'PROJECTOR_CTRL_POWER'} ne $last{'PROJECTOR_CTRL_POWER'})
	{
		if ($exists{'PROJECTOR_CTRL_POWER'} eq 'OFF' || $exists{'PROJECTOR_CTRL_POWER'} eq 'ON') {
			$projLast = 0;
			DMX::say('Projector: ' . lc($exists{'PROJECTOR_CTRL_POWER'}));

			# Announce lamp life status, if near/past $LAMP_LIFE
			if (exists($exists{'PROJECTOR_CTRL_LIFE'}) && $exists{'PROJECTOR_CTRL_LIFE'} > $PROJ_FACTOR) {
				my $chance = ($exists{'PROJECTOR_CTRL_LIFE'} - $PROJ_FACTOR) * (1 / (1 - $PROJ_FACTOR));
				if (rand(1) <= $chance) {
					DMX::say('Projector lamp has run for ' . int($exists{'PROJECTOR_CTRL_LIFE'} * 100) . '% of its estimated life.');
				}
			}
		}
	}

	# Speak when BRIGHT changes
	if (exists($exists{'BRIGHT'}) && exists($last{'BRIGHT'}) && $exists{'BRIGHT'} ne $last{'BRIGHT'}) {
		my $mode = 'NOMINAL';
		if ($exists{'BRIGHT'}) {
			$mode = 'FULL';
		}
		DMX::say('Lights - ' . lc($mode) . ' power');
	}

	# Speak when NO_MOTION changes
	if (exists($exists{'NO_MOTION'}) && exists($last{'NO_MOTION'}) && $exists{'NO_MOTION'} ne $last{'NO_MOTION'}) {
		my $mode = 'ENABLED';
		if ($exists{'NO_MOTION'}) {
			$mode = 'DISABLED';
		}
		DMX::say('Motion detectors: ' . lc($mode));
	}

	# Speak when LOCK changes
	if (exists($exists{'LOCK'}) && exists($last{'LOCK'}) && $exists{'LOCK'} ne $last{'LOCK'}) {
		my $mode = 'UNLOCKED';
		if ($exists{'LOCK'}) {
			$mode = 'LOCKED';
		}

		DMX::say('System ' . lc($mode));
	}

	# Speak when ALARM_ENABLE changes
	if (exists($exists{'ALARM_ENABLE'}) && exists($last{'ALARM_ENABLE'}) && $exists{'ALARM_ENABLE'} ne $last{'ALARM_ENABLE'}) {
		my $mode = 'DISABLED';
		if ($exists{'ALARM_ENABLE'}) {
			$mode = 'ENABLED';
		}

		DMX::say('Alarm ' . lc($mode));
	}

	# Email when ALARM is asserted
	if (exists($exists{'ALARM'}) && exists($last{'ALARM'}) && $exists{'ALARM'} && !$last{'ALARM'}) {
		my @exists_tmp = ();
		foreach my $key (sort(keys(%exists))) {
			push(@exists_tmp, $key . ":\t" . $exists{$key} . ' @ ' . $mtime{$key});
		}

		my $message = Email::MIME->create(
			header_str => [
				To      => 'zach@kotlarek.com',
				From    => $ENV{'USER'} . '@' . Sys::Hostname::hostname(),
				Subject => 'Alarm Activated',
			],
			attributes => {
				encoding => 'quoted-printable',
				charset  => 'ISO-8859-1',
			},
			body_str => 'Alarm activated: ' . localtime() . "\n\nState: " . $cmdState . "\n" . join("\n", @exists_tmp) . "\n",
		);
		sendmail($message);
	}

	# Ongoing spoken ALARM
	if ($exists{'ALARM'}) {
		if ($now - $alarmLast > $ALARM_DELAY) {
			$alarmLast = $now;
			DMX::say('Unauthorized access detected.');
		}
	}
}
