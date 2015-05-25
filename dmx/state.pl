#!/usr/bin/perl
use strict;
use warnings;
use IO::Select;
use File::Basename;
use File::Temp qw( tempfile );
use Sys::Hostname;
use IPC::System::Simple qw( system capture );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Prototypes
sub mtime($);

# User config
my %DISPLAY_DEVS   = ('TV' => 1, 'PROJECTOR' => 1);
my $DISPLAY        = undef();
my $STATE_TIMEOUT  = 180;
my $EXISTS_TIMEOUT = 900;
my $START_DELAY    = 15;
my %MON_FILES      = ();

# Host-specific config
# This is necessary to avoid contention on shared disks
my $HOST = Sys::Hostname::hostname();
if ($HOST =~ /loki/i) {

	# Ensure the media path is available before we get going
	my $MEDIA_PATH = undef();
	{
		my $mount = $ENV{'HOME'} . '/bin/video/mediaPath';
		$MEDIA_PATH = capture($mount);
	}
	if (!$MEDIA_PATH || !-d $MEDIA_PATH) {
		die("Unable to access media path\n");
	}

	# Garage door opener
	$MON_FILES{ $MEDIA_PATH . '/DMX/cmd/GARAGE_CMD' } = 'EXISTS-LINE-CLEAR';

	# Rumble pack
	$MON_FILES{'RUMBLE'}                                    = 'LINE-NOUPDATE';
	$MON_FILES{ $MEDIA_PATH . '/DMX/cmd/RUMBLE_CMD' }       = 'LINE-NOUPDATE';
	$MON_FILES{ $MEDIA_PATH . '/DMX/cmd/RUMBLE_VALUE' }     = 'LINE-NOUPDATE';
	$MON_FILES{ $MEDIA_PATH . '/DMX/cmd/RUMBLE_DELAY_MIN' } = 'LINE-NOUPDATE';
	$MON_FILES{ $MEDIA_PATH . '/DMX/cmd/RUMBLE_DELAY_MAX' } = 'LINE-NOUPDATE';
}

# Available state files
{

	# Plex
	$MON_FILES{'PLEX'}    = 'NONE';
	$MON_FILES{'GUI'}     = 'NONE';
	$MON_FILES{'PLAYING'} = 'PLAYING';

	# RiffTrax
	$MON_FILES{'RIFF'} = 'LINE-NOUPDATE';

	# Motion detection
	$MON_FILES{'MOTION'}        = 'MTIME';
	$MON_FILES{'MOTION_STAIRS'} = 'MTIME-NOUPDATE';
	$MON_FILES{'NO_MOTION'}     = 'EXISTS-NOUPDATE';

	# Projector
	$MON_FILES{'PROJECTOR'}       = 'STATUS';
	$MON_FILES{'PROJECTOR_COLOR'} = 'LINE-NOUPDATE';
	$MON_FILES{'PROJECTOR_INPUT'} = 'LINE-NOUPDATE';
	$MON_FILES{'PROJECTOR_LAMP'}  = 'LINE-NOUPDATE';

	# Amplifier
	$MON_FILES{'AMPLIFIER'}       = 'STATUS';
	$MON_FILES{'AMPLIFIER_VOL'}   = 'LINE-NOUPDATE';
	$MON_FILES{'AMPLIFIER_MODE'}  = 'LINE-NOUPDATE';
	$MON_FILES{'AMPLIFIER_INPUT'} = 'LINE-NOUPDATE';
	$MON_FILES{'AUDIO_AMP'}       = 'EXISTS-ON';
	$MON_FILES{'STEREO_CMD'}      = 'EXISTS-ON';

	# A/V Effects
	$MON_FILES{'LIGHTS'} = 'EXISTS-TIMEOUT';
	$MON_FILES{'BRIGHT'} = 'EXISTS-TIMEOUT';
	$MON_FILES{'RAVE'}   = 'EXISTS';
	$MON_FILES{'EFFECT'} = 'EXISTS';

	# Equipment
	$MON_FILES{'FAN'}     = 'LINE-NOUPDATE';
	$MON_FILES{'FAN_CMD'} = 'EXISTS-TIMEOUT';
	$MON_FILES{'LOCK'}    = 'EXISTS-NOUPDATE';
	$MON_FILES{'ALARM'}   = 'NONE';

	# OS State
	$MON_FILES{'FRONT_APP'}   = 'LINE-NOUPDATE';
	$MON_FILES{'COLOR'}       = 'LINE-NOUPDATE';
	$MON_FILES{'AUDIO'}       = 'LINE-NOUPDATE';
	$MON_FILES{'AUDIO_STATE'} = 'LINE-NOUPDATE';

	# Lights
	$MON_FILES{'LED'}      = 'LINE-NOUPDATE';
	$MON_FILES{'OVERHEAD'} = 'LINE-NOUPDATE';
	$MON_FILES{'ROPE'}     = 'LINE-NOUPDATE';
	$MON_FILES{'STAIRS'}   = 'LINE-NOUPDATE';

	# TV
	$MON_FILES{'TV'}       = 'STATUS';
	$MON_FILES{'TV_VOL'}   = 'LINE-NOUPDATE';
	$MON_FILES{'TV_INPUT'} = 'LINE-NOUPDATE';
}
my %EXTRAS = (
	'PLAYING' => {
		'URL'       => qr/^file:(.+)$/m,
		'YEAR'      => qr/^year:(\d+)/m,
		'SERIES'    => qr/^showtitle:(.+)$/m,
		'SEASON'    => qr/^season:(\d+)/m,
		'EPISODE'   => qr/^episode:(\d+)/m,
		'TITLE'     => qr/^title:(.+)$/m,
		'LENGTH'    => qr/^duration:(\d+)/m,
		'POSITION'  => qr/^time:(\d+(?:\.\d+)?)/m,
		'TYPE'      => qr/^type:(.+)$/m,
		'ALBUM'     => qr/^album:(.+)$/m,
		'ARTIST'    => qr/^artist:(.+)$/m,
		'SELECTION' => qr/^selection:(.+)$/m,
		'WINDOW'    => qr/^window:(.+)$/m,
		'WINDOWID'  => qr/^windowid:(\d+)/m,

		# Available, but big and mostly useless
		#'IMAGE'     => qr/^fanart:(.+)$/m,
		#'THUMB'     => qr/^thumbnail:(.+)$/m,
	}
);

# App config
my $SOCK_TIMEOUT = 5;
my $DATA_DIR     = DMX::dataDir();
my $CMD_FILE     = 'STATE';
my $MAX_CMD_LEN  = DMX::maxCmdLen();
my $RESET_CMD    = $ENV{'HOME'} . '/bin/video/dmx/reset.sh';
my $PUSH_TIMEOUT = 20;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Command-line arguments
my ($DELAY) = @ARGV;
if (!$DELAY) {
	$DELAY = 0.5;
}

# Socket init
my $select = DMX::stateSocket($CMD_FILE);

# Add the extras to the main file list
foreach my $file (keys(%EXTRAS)) {
	if (exists($MON_FILES{$file})) {
		foreach my $extra (keys(%{ $EXTRAS{$file} })) {
			$MON_FILES{ $file . '_' . $extra } = 'EXTRA';
		}
	}
}

# Init the file tracking structure
my %files = ();
foreach my $name (keys(%MON_FILES)) {
	my %file = (
		'name'   => basename($name),
		'type'   => $MON_FILES{$name},
		'path'   => $DATA_DIR . $name,
		'update' => 0,
		'value'  => 0,
		'last'   => 0,
	);

	# Allow absolute paths to override the $DATA_DIR path
	if ($name =~ /^\//) {
		$file{'path'} = $name;
	}

	# Record the directory name for folder monitoring
	$file{'dir'} = dirname($file{'path'});

	# Set the attribute bits, for use in later update handling logic
	my %attr = (
		'available' => 0,
		'status'    => 0,
		'exists'    => 0,
		'value'     => 0,
		'line'      => 0,
		'clear'     => 0,
		'clear_off' => 0,
		'mtime'     => 0,
		'playing'   => 0,
		'no_update' => 0,
		'no_value'  => 0,
		'extra'     => 0,
	);
	if ($file{'type'} =~ /\bSTATUS\b/i) {
		$attr{'status'} = 1;
	}
	if ($file{'type'} =~ /\bEXISTS\b/i) {
		$attr{'exists'} = 1;
	}
	if ($file{'type'} =~ /\bVALUE\b/i) {
		$attr{'value'} = 1;
	}
	if ($file{'type'} =~ /\bLINE\b/i) {
		$attr{'line'} = 1;
	}
	if ($file{'type'} =~ /\bCLEAR\b/i) {
		$attr{'clear'} = 1;
	}
	if ($file{'type'} =~ /\bON\b/i) {
		$attr{'clear_off'} = 1;
	}
	if ($file{'type'} =~ /\bTIMEOUT\b/i) {
		$attr{'clear_timeout'} = 1;
	}
	if ($file{'type'} =~ /\bMTIME\b/i) {
		$attr{'mtime'} = 1;
	}
	if ($file{'type'} =~ /\bPLAYING\b/i) {
		$attr{'playing'} = 1;
	}
	if ($file{'type'} =~ /\bNOUPDATE\b/i) {
		$attr{'no_update'} = 1;
	}
	if ($file{'type'} =~ /\bNONE\b/i) {
		$attr{'no_value'} = 1;
	}
	if ($file{'type'} =~ /\bEXTRA\b/i) {
		$attr{'extra'} = 1;
	}

	# Cross-match some data types for easy of use
	if ($attr{'extra'}) {
		$attr{'no_value'} = 1;
	}
	if ($attr{'no_value'}) {
		$attr{'no_update'} = 1;
	}
	if ($attr{'line'}) {
		$attr{'value'} = 1;
	}
	if ($attr{'value'} || $attr{'playing'}) {
		$attr{'status'} = 1;
	}
	if ($attr{'status'} || $attr{'exists'}) {
		$attr{'mtime'} = 1;
	}

	# Push ATTR into the file hash
	$file{'attr'} = \%attr;

	# Push FILE into the files hash
	$files{$name} = \%file;
}

# Delete any existing input files, to ensure our state is reset
foreach my $file (values(%files)) {
	if (-e $file->{'path'}) {
		if ($DEBUG) {
			print STDERR 'Deleting ' . $file->{'name'} . ': ' . $file->{'path'} . "\n";
		}
		unlink($file->{'path'});
	}
}

# Reset all dependents at starts
system($RESET_CMD);

# Subscribers
my @subscribers = ();

# State
my $state           = 'INIT';
my $stateLast       = $state;
my $status          = '';
my $statusLast      = $status;
my $updateLast      = 0;
my $timeSinceUpdate = 0;
my $startTime       = time() + $START_DELAY;
my $pushLast        = 0;

# Announce startup
DMX::say('System initializing');

# Loop forever
while (1) {

	# Provide a method to force updates
	my $update = 0;

	# Avoid repeated calls to time()
	my $now = time();

	# Check for queued commands
	my @ready_clients = $select->can_read($DELAY);
	foreach my $fh (@ready_clients) {

		# Grab the inbound text
		my $path = undef();
		$fh->recv($path, $MAX_CMD_LEN);
		$path =~ s/^\s+//;
		$path =~ s/\s+$//;
		$path =~ s/\W/_/g;
		if ($DEBUG) {
			print STDERR 'Got path: ' . $path . "\n";
		}

		# Open the new socket
		my $sub = eval { DMX::clientSock($path); };
		if (!$sub) {
			print STDERR 'Unable to open socket: ' . $path . ": ${@}\n";
			next;
		}

		# Add the socket to our subscriber list
		my %tmp = (
			'path'   => $path,
			'socket' => $sub,
		);
		push(@subscribers, \%tmp);

		# Send immediately when someone subscribes
		if (!$update) {
			if ($DEBUG) {
				print STDERR "New subscriber\n";
			}
			$update = 1;
		}
	}

	# Use opendir/readdir in each folder to ensure fresh results
	my %folders = ();
	foreach my $file (values(%files)) {
		if (!$folders{ $file->{'dir'} }) {
			my $dh = undef();
			opendir($dh, $file->{'dir'})
			  or die('Unable to open directory: ' . $file->{'dir'});
			if ($DEBUG) {
				print STDERR 'Refreshed folder: ' . $file->{'dir'} . "\n";
			}
			my @files = readdir($dh);
			closedir($dh);
			$folders{ $file->{'dir'} } = 1;
		}
	}

	# Monitor files of all types
	foreach my $file (values(%files)) {

		# Record the previous status and clear the new one, unless the file is type EXTRA
		if (!$file->{'attr'}->{'extra'}) {
			$file->{'last'}  = $file->{'value'};
			$file->{'value'} = 0;
		}

		# Skip NO_VALUE files -- their values are abstracted from other data
		if ($file->{'attr'}->{'no_value'}) {
			next;
		}

		# Track available/unavailable status in each cycle
		{
			my $wasAvailable = $file->{'attr'}->{'available'};
			$file->{'attr'}->{'available'} = -r $file->{'path'} ? 1 : 0;
			if ($wasAvailable != $file->{'attr'}->{'available'}) {

				# Reset and extras for this file
				if (exists($EXTRAS{ $file->{'name'} })) {
					foreach my $extra (keys(%{ $EXTRAS{ $file->{'name'} } })) {
						my $name = $file->{'name'} . '_' . $extra;
						$files{$name}{'last'}  = $files{$name}{'value'};
						$files{$name}{'value'} = 0;
					}
				}

				# Determine which display device we have (if any)
				if (exists($DISPLAY_DEVS{ $file->{'name'} })) {
					$DISPLAY = $file->{'name'};
					if ($DEBUG) {
						print STDERR 'Selecting display device: ' . $DISPLAY . "\n";
					}
				}

				if ($DEBUG) {
					if ($file->{'attr'}->{'available'}) {
						print STDERR 'Added file ' . $file->{'name'} . ': ' . $file->{'path'} . "\n";
					} else {
						print STDERR 'Dropped file ' . $file->{'name'} . ': ' . $file->{'path'} . "\n";
					}
				}
			}
		}

		# Skip unavailable files
		if (!$file->{'attr'}->{'available'}) {
			next;
		}

		# Record the last update for MTIME files
		if ($file->{'attr'}->{'mtime'}) {
			my $mtime = mtime($file->{'path'});

			# All EXISTS files have MTIME set, and mtime returns 0 if the file does not exist, so we can overload this check
			if ($file->{'attr'}->{'exists'}) {
				if ($mtime > 0) {
					$file->{'update'} = $mtime;
					$file->{'value'}  = 1;
				} elsif ($file->{'last'}) {
					$file->{'update'} = $now;
				}
			} else {
				$file->{'update'} = $mtime;

				# Set the value if the update is recent -- VALUE and STATUS will overwrite as needed
				if ($mtime >= $now) {
					$file->{'value'} = 1;
				}
			}

			if ($DEBUG) {
				print STDERR 'Mtime: ' . $file->{'name'} . ': ' . $file->{'value'} . ':' . $file->{'update'} . "\n";
			}
		}

		# Grab the state from STATUS files (including VALUE files)
		if ($file->{'attr'}->{'status'}) {

			# Overwrite the mtime-based value
			$file->{'value'} = 0;

			my $text = '';
			{
				if (!open(my $fh, $file->{'path'})) {
					warn('Unable to open ' . $file->{'path'} . "\n");
				} else {
					local $/;
					$text = <$fh>;
					close($fh);
				}
			}

			# Parse the value for the file
			if ($file->{'attr'}->{'value'}) {
				if ($file->{'attr'}->{'line'}) {
					($text) = $text =~ /^([^\n]+)\s*\n/;
				} else {
					$text =~ s/\s+$//;
				}
				$file->{'value'} = $text;
			} elsif ($file->{'attr'}->{'playing'}) {
				if ($text =~ /^playing:1/m) {
					$file->{'value'} = 1;
				}
			} else {
				if ($text =~ /1/) {
					$file->{'value'} = 1;
				}
			}
			if ($DEBUG) {
				print STDERR 'Status: ' . $file->{'name'} . ': ' . $file->{'value'} . "\n";
			}

			# Handle extras, if any
			if (exists($EXTRAS{ $file->{'name'} })) {
				foreach my $extra (keys(%{ $EXTRAS{ $file->{'name'} } })) {

					my $name = $file->{'name'} . '_' . $extra;
					$files{$name}{'last'}   = $files{$name}{'value'};
					$files{$name}{'value'}  = 0;
					$files{$name}{'update'} = $file->{'update'};

					if ($text =~ $EXTRAS{ $file->{'name'} }{$extra}) {
						$files{$name}{'value'} = $1;
					}

					if ($DEBUG) {
						print STDERR "\t" . $name . ': ' . $files{$name}{'value'} . "\n";
					}
				}
			}
		}
	}

	# Simulate the old GUI indicator
	{
		my $gui = 0;
		if (exists($files{'PLAYING_WINDOW'}) && $files{'PLAYING_WINDOW'}->{'value'} ne 'Fullscreen video') {
			$gui = 1;
		}
		$files{'GUI'}->{'value'} = $gui;
	}
	if (exists($files{'PLAYING'})) {
		$files{'GUI'}->{'update'} = $files{'PLAYING'}->{'update'};
	}

	# Ignore the MOTION file if NO_MOTION is set
	if (exists($files{'NO_MOTION'}) && $files{'NO_MOTION'}->{'value'}) {
		if (exists($files{'MOTION'})) {
			$files{'MOTION'}->{'value'}  = 0;
			$files{'MOTION'}->{'update'} = 0;
		}
	}

	# Set the global update timestamp, excluding files marked NOUPDATE
	foreach my $file (values(%files)) {
		if (   $file->{'update'} > $updateLast
			&& !$file->{'attr'}->{'no_update'}
			&& $file->{'update'} > $startTime)
		{
			$updateLast = $file->{'update'};
		}
	}
	$timeSinceUpdate = $now - $updateLast;

	# Calculate the PLEX state
	if (exists($files{'FRONT_APP'})) {
		if (   $files{'FRONT_APP'}->{'value'} =~ 'com.plexapp.plexhometheater'
			|| $files{'FRONT_APP'}->{'value'} eq 'com.apple.ScreenSaver.Engine')
		{
			$files{'PLEX'}->{'value'} = 1;
		}
	}
	if ($files{'PLEX'}->{'last'} != $files{'PLEX'}->{'value'}) {
		$files{'PLEX'}->{'update'} = $now;
	}

	# Determine some intermediate state data
	my $playing = 0;
	if (exists($files{'PLAYING'}) && $files{'PLAYING'}->{'value'}) {
		$playing = 1;
	}
	my $video = 0;
	if (exists($files{'PLAYING_TYPE'}) && $files{'PLAYING_TYPE'}->{'value'} ne 'audio') {
		$video = 1;
	} elsif (!exists($files{'PLAYING_TYPE'})) {
		$video = 1;
	}

	# Non-plex apps are always "playing" and "video"
	if (exists($files{'PLEX'}) && !$files{'PLEX'}->{'value'}) {
		$playing = 1;
		$video   = 1;
	}

	# Calculate the new state
	$stateLast = $state;
	if (!defined($DISPLAY) || !exists($files{$DISPLAY})) {

		# If there's no display the state is always PLAY or PAUSE, as indicated by the master
		if ($playing) {
			$state = 'PLAY';
		} else {
			$state = 'PAUSE';
		}

	} elsif ($files{$DISPLAY}->{'value'}) {

		# If a display exists and is on:
		# PLAY when video is active and playing
		# PAUSE any other time (including when audio is active)
		if ($playing && $video) {
			$state = 'PLAY';
		} else {
			$state = 'PAUSE';
		}

	} else {

		# If the display exists but is off, check the timeouts to determine MOTION vs. OFF
		if ($timeSinceUpdate > $STATE_TIMEOUT) {
			$state = 'OFF';
		} elsif ($timeSinceUpdate < $STATE_TIMEOUT) {
			$state = 'MOTION';
		}
	}
	if ($state eq 'INIT') {
		$state = 'OFF';
	}

	# ALARM if LOCK exists and the master state is not OFF or any motion exists
	{
		my $alarm = 0;
		if (exists($files{'LOCK'}) && $files{'LOCK'}->{'value'}) {
			if (   $state ne 'OFF'
				|| (exists($files{'MOTION'}) && $files{'MOTION'}->{'value'})
				|| (exists($files{'MOTION_STAIRS'}) && $files{'MOTION_STAIRS'}->{'value'}))
			{
				$alarm = 1;
			}
		}
		if (!exists($files{'ALARM'}->{'value'}) || $files{'ALARM'}->{'value'} != $alarm) {
			$files{'ALARM'}->{'update'} = $now;
		}
		$files{'ALARM'}->{'value'} = $alarm;
	}

	# Clear EXISTS_ON files when the main state is "OFF" (and before we append their status)
	foreach my $file (values(%files)) {
		if (   $file->{'attr'}->{'clear_off'}
			&& $file->{'value'}
			&& $state eq 'OFF')
		{
			unlink($file->{'path'});
			$file->{'status'} = 0;
			if ($DEBUG) {
				print STDERR 'Clearing exists flag for: ' . $file->{'name'} . "\n";
			}
		}
	}

	# Clear EXISTS_TIMEOUT files when the main state is "OFF" and EXISTS_TIMEOUT has expired (and before we append their status)
	foreach my $file (values(%files)) {
		if (   $file->{'attr'}->{'clear_timeout'}
			&& $file->{'value'}
			&& $state eq 'OFF'
			&& $timeSinceUpdate > $EXISTS_TIMEOUT)
		{

			unlink($file->{'path'});
			$file->{'status'} = 0;
			if ($DEBUG) {
				print STDERR 'Clearing exists flag for: ' . $file->{'name'} . "\n";
			}
		}
	}

	# Calculate the new status
	$statusLast = $status;
	{
		my @statTime = ();
		foreach my $file (values(%files)) {
			my $text = $file->{'value'};
			$text =~ s/\s/ /g;
			$text =~ s/\|/-/g;
			push(@statTime, $file->{'name'} . '|' . $text . '|' . $file->{'update'});
		}
		$status = "\n" . join("\n", @statTime);
	}

	# Clear EXISTS_CLEAR files immediately (but after we append their status)
	foreach my $file (values(%files)) {
		if ($file->{'attr'}->{'clear'} && $file->{'value'}) {
			unlink($file->{'path'});
			$file->{'status'} = 0;
			if ($DEBUG) {
				print STDERR 'Clearing exists flag for: ' . $file->{'name'} . "\n";
			}
		}
	}

	# Update on a periodic basis, so we don't timeout
	if (!$update && $now - $pushLast > $PUSH_TIMEOUT) {
		if ($DEBUG) {
			print STDERR "Periodic update\n";
		}
		$update = 1;
	}

	# Update on a master state change
	if (!$update && $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . ' => ' . $state . "\n";
		}
		$update = 1;
	}

	# Update on any mtime change
	if (!$update) {
		foreach my $file (values(%files)) {
			if ($file->{'update'} > $pushLast) {
				if ($DEBUG) {
					print STDERR 'Mtime change: ' . $file->{'name'} . ' (' . $file->{'update'} . ")\n";
				}
				$update = 1;
				last;
			}
		}
	}

	# Update on any value change
	if (!$update) {
		foreach my $file (values(%files)) {
			if ($file->{'value'} ne $file->{'last'}) {
				if ($DEBUG) {
					print STDERR 'Value change: ' . $file->{'name'} . ' (' . $file->{'last'} . ' => ' . $file->{'value'} . ")\n";
				}
				$update = 1;
				last;
			}
		}
	}

	# Push the update
	if ($update) {

		# Note the push
		$pushLast = $now;

		# Send notifications to all subscribers
		my $msg = $state . $status;
		if ($DEBUG) {
			print STDERR '<STATE (' . length($msg) . ")>\n" . $msg . "\n<END STATE>\n\n";
		}
		foreach my $sub (@subscribers) {

			# Drop subscribers that are not available
			if (!eval { $sub->{'socket'}->send($state . $status) }) {
				print STDERR 'Dropping bad socket from subscriber list: ' . $sub->{'path'} . "\n";

				my @new_subscribers = ();
				foreach my $new (@subscribers) {
					if ($new->{'socket'} eq $sub->{'socket'}) {
						next;
					}
					push(@new_subscribers, $new);
				}
				@subscribers = @new_subscribers;
			}
		}

		# Save the state and value to disk
		my ($fh, $tmp) = tempfile($DATA_DIR . 'STATE.XXXXXXXX', 'UNLINK' => 0);
		print $fh $state . "\n";
		close($fh);
		rename($tmp, $DATA_DIR . 'STATE');
	}
}

sub mtime($) {
	my ($file) = @_;
	my $mtime = 0;
	if (-r $file) {
		(undef(), undef(), undef(), undef(), undef(), undef(), undef(), undef(), undef(), $mtime, undef(), undef(), undef()) = stat($file);
	}
	return $mtime;
}
