#!/usr/bin/perl
use strict;
use warnings;
use File::Temp qw( tempfile );
use Time::HiRes qw( usleep sleep time );
use IPC::System::Simple qw( system capture );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;
use Audio;

# Config
my $MEDIA_PATH     = `~/bin/video/mediaPath`;
my $CONFIG_PATH    = $MEDIA_PATH . '/DMX/RiffTrax';
my $RIFF_PATH      = $MEDIA_PATH . '/iTunes/iTunes Music/RiffTrax';
my $ACTION_DELAY   = 0.1;
my $JUMP_THRESHOLD = 5;

# Prototypes
sub playRiff();
sub pauseRiff();

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'RIFF';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $PULL_TIMEOUT = 60;
my $DELAY        = $PULL_TIMEOUT / 3;
my %RIFFS        = ();

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Read the config
opendir(CONF, $CONFIG_PATH)
  or die('Unable to open config directory: ' . $! . "\n");
foreach my $file (readdir(CONF)) {

	# Skip silly files
	if ($file =~ /^\._/) {
		next;
	}

	if ($file =~ /\.riff$/) {
		my $path = $CONFIG_PATH . '/' . $file;

		# Slurp the contents
		my $text = '';
		if (!open(my $fh, $path)) {
			warn('Unable to open ' . $path . "\n");
		} else {
			local $/;
			$text = <$fh>;
			close($fh);
		}

		# Parse out the data we care about
		my %data = ();
		if ($text =~ /^\s*Name:\s*(\S.*\S)\s*$/mi) {
			$data{'name'} = $1;
		}
		if ($text =~ /^\s*File:\s*(\S.*\S)\s*$/mi) {
			$data{'file'} = $1;
		}
		if ($text =~ /^\s*Offset:\s*([\-\+]?\d+(?:\.\d+)?)\s*$/mi) {
			$data{'offset'} = $1;
		}
		if ($text =~ /^\s*Rate:\s*(\d+(?:\.\d+)?)\s*$/mi) {
			$data{'rate'} = $1;
		}

		# Ensure we have a valid record
		if (!$data{'name'} || !$data{'file'}) {
			die('Invalid riff file: ' . $file . ' => ' . $data{'name'} . "\n");
		}

		# Construct an absolute path
		if ($data{'file'} =~ /^\//) {
			$data{'path'} = $data{'file'};
		} else {
			$data{'path'} = $RIFF_PATH . '/' . $data{'file'};
		}

		# Ensure the path is valid
		if (!-r $data{'path'}) {
			die('Invalid riff path: ' . $file . ' => ' . $data{'path'} . "\n");
		}

		# Debug
		if ($DEBUG) {
			print STDERR 'Added RiffTrax: ' . $data{'name'} . "\n\tFile: " . $data{'file'} . "\n\tOffset: " . $data{'offset'} . "\n\tRate: " . $data{'rate'} . "\n";
		}

		# Push the data up the chain
		$RIFFS{ $data{'name'} } = \%data;
	}
}
closedir(CONF);

# Sockets
DMX::stateSocket($STATE_SOCK);
DMX::stateSubscribe($STATE_SOCK);

# State
my $state     = 'OFF';
my $stateLast = $state;
my $riff      = '';
my $riffLast  = $riff;
my $title     = '';
my $titleLast = $title;
my $nudge     = 0;
my %exists    = ();
my %last      = ();
my $pullLast  = time();
my $lastSync  = time();
my $playing   = 0;
my $delay     = $DELAY;

# Loop forever
while (1) {

	# Save the last RIFF and state
	$stateLast = $state;
	$riffLast  = $riff;
	%last      = %exists;

	# Reconnect if we're playing and haven't seen an update for $JUMP_THRESHOLD seconds
	if ($playing && time() - $pullLast > $JUMP_THRESHOLD) {
		print STDERR "Attempting to reconnect state socket...\n";
		DMX::stateSubscribe($STATE_SOCK);
	}

	# Wait for state updates
	my $cmdState = DMX::readState($delay, \%exists, undef(), undef());
	if (defined($cmdState)) {
		$state    = $cmdState;
		$pullLast = time();
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Record nudges
	if ($state eq 'NUDGE_FORWARD') {
		$nudge -= 0.1;
		next;
	} elsif ($state eq 'NUDGE_BACK') {
		$nudge += 0.1;
		next;
	}

	# Save the last URL, so we can find changes
	# Do not delete the last URL if no new one is provided
	if (exists($exists{'PLAYING_TITLE'})) {
		$titleLast = $title;
		$title     = $exists{'PLAYING_TITLE'};
	}

	# Update our state when the PLAYING_TITLE changes
	if ($title ne $titleLast) {

		# If a RIFF was active, clear it
		if ($riff) {
			if ($DEBUG) {
				print STDERR "RIFF complete\n";
			}
			$delay = $DELAY;
			Audio::drop('RIFF');
			$riff  = 0;
			$nudge = 0;
			DMX::say('RiffTrax complete');
		}

		# Activate a new RIFF, if applicable
		if ($RIFFS{$title}) {
			if ($DEBUG) {
				print STDERR 'Matched RIFF: ' . $title . ' => ' . $RIFFS{$title}->{'file'} . "\n";
			}
			$riff  = $title;
			$delay = 1;
			Audio::addLoad('RIFF', $RIFFS{$riff}->{'path'});
			Audio::rate('RIFF', $RIFFS{$riff}->{'rate'});
			playRiff();
			DMX::say('RiffTrax initiated');
		}
	}

	# If the RIFF has changed, save the state to disk
	if ($riff ne $riffLast) {
		my $new = '<none>';
		if ($riff) {
			$new = $RIFFS{$riff}->{'name'};
		}
		my $old = $new;
		if ($riffLast > 0) {
			$old = $RIFFS{$riffLast}->{'name'};
		}

		if ($DEBUG) {
			print STDERR 'New RIFF: ' . $old . ' => ' . $new . "\n";
		}

		my ($fh, $tmp) = tempfile($OUTPUT_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $new . "\n";
		close($fh);
		rename($tmp, $OUTPUT_FILE);
	}

	# Play/pause to match the video
	# This assumes our local state is valid. We double-check that state tracking if the sync error is large enough to trigger a jump
	if ($riff) {
		if ($state eq 'PAUSE' && $playing) {
			pauseRiff();
		} elsif ($state eq 'PLAY' && !$playing) {
			playRiff();
		}
	}

	# Sync at most once per second
	if ($riff && $lastSync < time()) {
		if ($DEBUG) {
			print STDERR "Syncing\n";
		}
		$lastSync = time();

		# Get the video and riff playback positions
		my $rate = Audio::rate('RIFF', undef());
		my $riffTime = Audio::position('RIFF', undef());
		my $videoTime = $exists{'PLAYING_POSITION'};

		# Convert to seconds
		my @parts = split(/\:/, $videoTime);
		$videoTime = 0;
		if (scalar(@parts) == 3) {
			$videoTime = ($parts[0] * 3600) + ($parts[1] * 60) + $parts[2];
		} elsif (scalar(@parts) == 2) {
			$videoTime = ($parts[0] * 60) + $parts[1];
		} else {
			$videoTime = $parts[0];
		}

		# Calculate the adjusted riff time and the error between the riff and video times
		my $riffAdjTime = ($riffTime * $RIFFS{$riff}->{'rate'}) - $RIFFS{$riff}->{'offset'} + $nudge;
		my $error       = $videoTime - $riffAdjTime;
		my $errorAbs    = abs($error);

		# Debug
		if ($DEBUG) {
			print STDERR "\tRate: " . $RIFFS{$riff}->{'rate'} . "\n";
			print STDERR "\tAdjusted Rate: " . $rate . "\n";
			print STDERR "\tNudge: " . $nudge . "\n";
			print STDERR "\tOffset: " . $RIFFS{$riff}->{'offset'} . "\n";
			print STDERR "\tRiff time: " . $riffTime . "\n";
			print STDERR "\tVideo time: " . $videoTime . "\n";
			print STDERR "\tAdjusted riff time: " . $riffAdjTime . "\n";
			print STDERR "\tError: " . $error . "\n";
		}

		# Adjust the riff position if we're off by 0.5 seconds or more
		if ($errorAbs > 0.5) {

			# Calculate the new position, including an ACTION_DELAY adjustment to compensate for time elapsed in this process
			my $newPos = $riffTime + $error + $ACTION_DELAY;

			if ($newPos < 0) {
				pauseRiff();
			} else {

				# Ensure our local playing state tracking is accurate
				$playing = Audio::playing('RIFF');

				# Jump if we're off by more than a few seconds
				if ($errorAbs > $JUMP_THRESHOLD) {
					if ($DEBUG) {
						print STDERR 'Jumping to: ' . $newPos . "\n";
					}
					Audio::position('RIFF', $newPos);
					$nudge    = 0;
					$error    = 0;
					$errorAbs = 0;
				}

				# Set the rate when we adjust, unless we're paused
				if ($playing) {
					my $rateDiff = $errorAbs / $JUMP_THRESHOLD;
					if ($error < 0) {
						$rateDiff *= -1;
					}
					my $newRate = $RIFFS{$riff}->{'rate'} + $rateDiff;
					if ($DEBUG) {
						print STDERR 'Setting rate to: ' . $newRate . "\n";
					}
					Audio::rate('RIFF', $newRate);
				}

				# Play/pause as needed, before we adjust
				# The state-change detection should handle most of this
				# But double-check while adjusting in case things get out-of-sync
				if (exists($exists{'PLAYING'})) {
					if ($exists{'PLAYING'} && !$playing) {
						playRiff();
					} elsif (!$exists{'PLAYING'} && $playing) {
						pauseRiff();
					}
				}
			}
		} else {

			# Reset the rate to standard if we're inside sync the window
			if ($rate != $RIFFS{$riff}->{'rate'}) {
				Audio::rate('RIFF', $RIFFS{$riff}->{'rate'});
			}
		}
	}
}

sub playRiff() {
	$playing = 1;
	Audio::background('RIFF');
}

sub pauseRiff() {
	$playing = 0;
	Audio::pause('RIFF');
}
