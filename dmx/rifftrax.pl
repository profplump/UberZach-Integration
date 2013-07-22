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
my $ACTION_DELAY   = 0.1;
my $JUMP_THRESHOLD = 5;
my $LEADIN_TIME    = 5;
my $VOLUME_RIFF    = 65;
my $VOLUME_STD     = 40;
my $VOL_STEP       = 1 / 20;
my $CONFIG_DELAY   = 300;

# Prototypes
sub playRiff();
sub pauseRiff();
sub getRiffRate();
sub setRiffRate($);
sub parseConfig($$);
sub playPausePlex();

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
my %exists    = ();
my %last      = ();
my $pullLast  = time();
my $lastSync  = time();
my $playing   = 0;
my $delay     = $DELAY;
my $leadin    = 0;

# Read the config
parseConfig($CONFIG_PATH, \%RIFFS);

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

	# Re-read the config on-demand
	if ($state eq 'HUP') {
		parseConfig($CONFIG_PATH, \%RIFFS);

		# Skip further processing this loop -- the exists hash is useless
		next;
	}

	# Re-read the config periodically (unless we are currently playing)
	if (!$riff && time() > $RIFFS{'_LAST_CONFIG_UPDATE'} + $CONFIG_DELAY) {
		parseConfig($CONFIG_PATH, \%RIFFS);
	}

	# Handle volume changes
	if ($riff) {
		if ($state eq 'VOL+' || $state eq 'VOL-') {

			# Calculate a relative volume
			my $vol = Audio::volume('RIFF', undef());
			if ($state eq 'VOL+') {
				$vol += $VOL_STEP;
			} else {
				$vol -= $VOL_STEP;
			}

			# Limit the range to 0.0 - 1.0
			if ($vol < 0) {
				$vol = 0;
			}
			if ($vol > 1) {
				$vol = 1;
			}

			# Set the document volume
			Audio::volume('RIFF', $vol);

			# Skip further processing this loop -- the exists hash is useless
			next;
		}
	}

	# Save the last URL, so we can find changes
	# Do not delete the last URL if no new one is provided
	if (exists($exists{'PLAYING_TITLE'})) {
		$titleLast = $title;
		$title     = $exists{'PLAYING_TITLE'};
	}

	# Convert the video timestamp to seconds
	my $videoTime = 0;
	if ($exists{'PLAYING_POSITION'}) {
		my @parts = split(/\:/, $exists{'PLAYING_POSITION'});
		$videoTime = 0;
		if (scalar(@parts) == 3) {
			$videoTime = ($parts[0] * 3600) + ($parts[1] * 60) + $parts[2];
		} elsif (scalar(@parts) == 2) {
			$videoTime = ($parts[0] * 60) + $parts[1];
		} else {
			$videoTime = $parts[0];
		}
	}

	# Update our state when the PLAYING_TITLE changes
	if ($title ne $titleLast) {

		# If a RIFF was active, clear it
		if ($riff) {
			if ($DEBUG) {
				print STDERR "RIFF complete\n";
			}

			# Increase the delay while nothing is happening
			$delay = $DELAY;

			# Reset the volume when we unload -- normal system sounds should be quieter than riffs
			Audio::systemVolume($VOLUME_STD);

			# Close the audio file
			Audio::unload('RIFF');
			$riff   = 0;
			$leadin = 0;

			# Warm fuzzies
			DMX::say('RiffTrax complete');
		}

		# Activate a new RIFF, if applicable
		# Always match on title, validate year if provided
		if ($RIFFS{$title}
			&& (!exists($RIFFS{$title}{'year'}) || $RIFFS{$title}{'year'} eq $exists{'PLAYING_YEAR'}))
		{

			if ($DEBUG) {
				print STDERR 'Matched RIFF: ' . $title . ' => ' . $RIFFS{$title}->{'file'} . "\n";
			}
			$riff = $title;

			# Warm fuzzies
			DMX::say('RiffTrax initiated');

			# Load and start the audio file
			Audio::load('RIFF', $RIFFS{$riff}->{'file'});
			playRiff();

			# Set volume when we load -- riffs should be louder than normal system sounds
			Audio::systemVolume($VOLUME_RIFF);
			Audio::volume('RIFF', 1.0);

			# Reduce the delay while playing so we sync faster
			$delay = 1;

			# Enable LEADIN if we're near the beginning of the movie
			if ($RIFFS{$riff}->{'offset'} > $LEADIN_TIME && $videoTime < $LEADIN_TIME) {
				playPausePlex();
				$leadin = 1;
			}
		}
	}

	# If the RIFF has changed, save the state to disk
	if ($riff ne $riffLast) {
		my $new = '<none>';
		if ($riff) {
			$new = $RIFFS{$riff}->{'name'};
		}
		my $old = $new;
		if ($riffLast) {
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

	# Skip further processing if we don't have valid state data from Plex
	if (!exists($exists{'PLAYING'})) {
		next;
	}

	# Play/pause to match the video or LEADIN state
	if ($riff) {
		if ($leadin) {
			if (!$playing) {
				playRiff();
			}
		} elsif (!$exists{'PLAYING'} && $playing) {
			pauseRiff();
		} elsif ($exists{'PLAYING'} && !$playing) {
			playRiff();
		}
	}

	# Skip further processing if we don't have valid sync data from Plex
	if (!$videoTime) {
		next;
	}

	# Sync at most once per second
	if ($riff && $lastSync < time()) {
		if ($DEBUG) {
			print STDERR "Syncing\n";
		}
		$lastSync = time();

		# Get the riff playback state
		my $rate = getRiffRate();
		my $riffTime = Audio::position('RIFF', undef());

		# Update our local playing state tracker
		# The rate is always 0 when paused (Audio::playing uses this same methodology)
		if ($rate > 0) {
			$playing = 1;
		} else {
			$playing = 0;
		}

		# Calculate the adjusted riff time and the error between the riff and video times
		my $riffAdjTime = $riffTime - $RIFFS{$riff}->{'offset'};
		my $error       = $videoTime - $riffAdjTime;
		my $errorAbs    = abs($error);

		# Debug
		if ($DEBUG) {
			print STDERR "\tRate: " . $rate . "\n";
			print STDERR "\tOffset: " . $RIFFS{$riff}->{'offset'} . "\n";
			print STDERR "\tRiff time: " . $riffTime . "\n";
			print STDERR "\tVideo time: " . $videoTime . "\n";
			print STDERR "\tAdjusted riff time: " . $riffAdjTime . "\n";
			print STDERR "\tError: " . $error . "\n";
			print STDERR "\tLeadin: " . $leadin . "\n";
		}

		# If LEADIN is still active
		if ($leadin) {

			# Deactivate LEADIN if the movie advances outside the LEADIN_TIME window
			if ($videoTime > $LEADIN_TIME) {
				$leadin = 0;
				if ($DEBUG) {
					print STDERR "LEADIN canceled due to video time\n";
				}
			}

			# Start the movie when we reach the sync point
			if ($RIFFS{$riff}->{'offset'} <= $riffTime) {
				if (!$exists{'PLAYING'}) {
					playPausePlex();
				}
				$leadin = 0;
				if ($DEBUG) {
					print STDERR "LEADIN canceled due to synchronization\n";
				}
			}

			# Skip normal syncing until LEADIN is cleared
			if ($leadin) {
				next;
			}
		}

		# Adjust the riff rate/position if we're off by 0.5 seconds or more
		if ($errorAbs > 0.5) {

			# Calculate the new position, including an ACTION_DELAY adjustment to compensate for time elapsed in this process
			my $newPos = $riffTime + $error + $ACTION_DELAY;

			if ($newPos < 0) {
				pauseRiff();
			} else {

				# Jump if we're off by more than a few seconds
				if ($errorAbs > $JUMP_THRESHOLD) {
					if ($DEBUG) {
						print STDERR 'Jumping to: ' . $newPos . "\n";
					}
					Audio::position('RIFF', $newPos);
					$error    = 0;
					$errorAbs = 0;
				}

				# Set the rate when we adjust, unless we're paused
				if ($playing) {
					my $rateDiff = $errorAbs / $JUMP_THRESHOLD;

					my $newRate = 1.0;
					if ($error < 0) {
						$newRate -= $rateDiff;
					} else {
						$newRate += $rateDiff;
					}

					if ($DEBUG) {
						print STDERR 'Setting rate to: ' . $newRate . "\n";
					}
					setRiffRate($newRate);
				}
			}
		} else {

			# Reset the rate to standard if we're inside sync the window
			if ($rate != 1.0) {
				setRiffRate(1.0);
			}
		}
	}
}

sub playRiff() {
	if ($DEBUG) {
		print STDERR "playRiff()\n";
	}
	$playing = 1;
	Audio::background('RIFF');
}

sub pauseRiff() {
	if ($DEBUG) {
		print STDERR "pauseRiff()\n";
	}
	$playing = 0;
	Audio::pause('RIFF');
}

sub getRiffRate() {
	if ($DEBUG) {
		print STDERR "getRiffRate()\n";
	}
	my $rate = 0;
	if ($playing) {
		$rate = Audio::rate('RIFF', undef());
	}
	return $rate;
}

sub setRiffRate($) {
	my ($rate) = @_;
	if ($DEBUG) {
		print STDERR 'setRiffRate(): ' . $rate . "\n";
	}
	if ($playing) {
		Audio::rate('RIFF', $rate);
	}
}

sub parseConfig($$) {
	my ($conf_path, $riffs) = @_;
	if ($DEBUG) {
		print STDERR "parseConfig()\n";
	}

	opendir(CONF, $conf_path)
	  or die('Unable to open config directory: ' . $! . "\n");
	foreach my $file (readdir(CONF)) {

		# Skip silly files
		if ($file =~ /^\._/) {
			next;
		}

		if ($file =~ /\.riff$/) {
			my $path = $conf_path . '/' . $file;

			# Slurp the contents
			my $text = '';
			if (!open(my $fh, $path)) {
				warn('Unable to open ' . $path . "\n");
				next;
			} else {
				local $/;
				$text = <$fh>;
				close($fh);
			}

			# Parse out the data we care about
			my %data = ();
			if ($text =~ /^\s*Name:[ \t]*(\S.*\S)\s*$/mi) {
				$data{'name'} = $1;
			}
			if ($text =~ /^\s*Year:[ \t]*(\d{4})\s*$/mi) {
				$data{'year'} = $1;
			}
			if ($text =~ /^\s*File:[ \t]*(\S.*\S)\s*$/mi) {
				$data{'file'} = $1;
			}
			if ($text =~ /^\s*Offset:[ \t]*([\-\+]?\d+(?:\.\d+)?)\s*$/mi) {
				$data{'offset'} = $1 * 1.0;
			}

			# Ensure we have a valid record
			if (!$data{'name'}) {
				warn('Invalid riff file: ' . $file . "\n");
				next;
			}

			# Try to find a related file
			if (!$data{'file'}) {
				$data{'file'} = $file;
				$data{'file'} =~ s/\.riff$/\.mp3/i;
				$data{'file'} = $conf_path . '/' . $data{'file'};
			}

			# Ensure the path is valid
			if (!-r $data{'file'}) {
				warn('Invalid MP3 file in riff ' . $file . ' => ' . $data{'file'} . "\n");
				next;
			}

			# Debug
			if ($DEBUG) {
				print STDERR 'Added RiffTrax: ' . $data{'name'} . "\n\tFile: " . $data{'file'} . "\n\tOffset: " . $data{'offset'} . "\n";
			}

			# Push the data up the chain
			$riffs->{ $data{'name'} } = \%data;
		}
	}
	closedir(CONF);

	# Record the last update time
	$riffs->{'_LAST_CONFIG_UPDATE'} = time();
}

# The UDP listener would be more portable, but I already know how to do this
# The PMS playback API would work too, but this script currently knows nothing of the PMS
sub playPausePlex() {
	Audio::runApplescript('tell application "System Events" to key code 49');
}
