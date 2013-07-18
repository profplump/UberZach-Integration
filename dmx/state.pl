#!/usr/bin/perl
use strict;
use warnings;
use IO::Select;
use File::Basename;
use File::Temp qw( tempfile );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Prototypes
sub mtime($);

# User config
my $MEDIA_PATH    = `~/bin/video/mediaPath`;
my %DISPLAY_DEVS  = ('TV' => 1, 'PROJECTOR' => 1);
my $DISPLAY       = '<NONE>';
my $STATE_TIMEOUT = 180;
my %MON_FILES     = ();

# Available state files
{

	# Plex
	$MON_FILES{'GUI'}     = 'GUI';
	$MON_FILES{'PLAYING'} = 'PLAYING';

	# RiffTrax
	$MON_FILES{'RIFF'} = 'VALUE';

	# Motion detection
	$MON_FILES{'MOTION'}    = 'MTIME';
	$MON_FILES{'NO_MOTION'} = 'EXISTS';

	# Projector
	$MON_FILES{'PROJECTOR'}       = 'STATUS';
	$MON_FILES{'PROJECTOR_COLOR'} = 'VALUE';
	$MON_FILES{'PROJECTOR_INPUT'} = 'VALUE';
	$MON_FILES{'PROJECTOR_LAMP'}  = 'VALUE';

	# Amplifier
	$MON_FILES{'AMPLIFIER'}       = 'STATUS';
	$MON_FILES{'AMPLIFIER_VOL'}   = 'VALUE';
	$MON_FILES{'AMPLIFIER_MODE'}  = 'VALUE';
	$MON_FILES{'AMPLIFIER_INPUT'} = 'VALUE';
	$MON_FILES{'AUDIO_AMP'}       = 'EXISTS-ON';
	$MON_FILES{'STEREO_CMD'}      = 'EXISTS-ON';

	# A/V Effects
	$MON_FILES{'LIGHTS'} = 'EXISTS-ON';
	$MON_FILES{'RAVE'}   = 'EXISTS';
	$MON_FILES{'EFFECT'} = 'EXISTS';

	# Equipment
	$MON_FILES{'FAN_CMD'} = 'EXISTS-ON';
	$MON_FILES{ $MEDIA_PATH . '/DMX/cmd/GARAGE_CMD' } = 'EXISTS-VALUE-CLEAR';

	# OS State
	$MON_FILES{'COLOR'}       = 'VALUE';
	$MON_FILES{'AUDIO'}       = 'VALUE';
	$MON_FILES{'AUDIO_STATE'} = 'VALUE';

	# TV
	$MON_FILES{'TV'}     = 'STATUS';
	$MON_FILES{'TV_VOL'} = 'VALUE';
}
my %EXTRAS = (
	'PLAYING' => {
		'URL'      => qr/^\<li\>Filename\:(.+)$/m,
		'YEAR'     => qr/^\<li\>Year\:(\d+)/m,
		'SERIES'   => qr/^\<li\>Show Title\:(.+)$/m,
		'SEASON'   => qr/^\<li\>Season\:(\d+)/m,
		'EPISODE'  => qr/^\<li\>Episode\:(\d+)/m,
		'TITLE'    => qr/^\<li\>Title\:(.+)$/m,
		'LENGTH'   => qr/^\<li\>Duration\:([\d\:]+)/m,
		'POSITION' => qr/^\<li\>Time\:([\d\:]+)/m,
		'SIZE'     => qr/^\<li\>File size\:(\d+)/m,
		'TYPE'     => qr/^\<li\>Type\:(.+)$/m,
	}
);

# App config
my $SOCK_TIMEOUT = 5;
my $DATA_DIR     = DMX::dataDir();
my $CMD_FILE     = $DATA_DIR . 'STATE.socket';
my $MAX_CMD_LEN  = 4096;
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
			$MON_FILES{ $file . '_' . $extra } = 'NONE';
		}
	}
}

# Init the file tracking structure
my %files = ();
foreach my $file (keys(%MON_FILES)) {
	my %tmp = (
		'name'   => basename($file),
		'type'   => $MON_FILES{$file},
		'path'   => $DATA_DIR . $file,
		'update' => 0,
		'value'  => 0,
		'last'   => 0,
	);

	# Allow absolute paths to override the $DATA_DIR path
	if ($file =~ /^\//) {
		$tmp{'path'} = $file;
	}

	# Record the directory name for folder monitoring
	$tmp{'dir'} = dirname($tmp{'path'});

	# Set the attribute bits, for use in later update handling logic
	my %attr = (
		'available' => 0,
		'status'    => 0,
		'exists'    => 0,
		'value'     => 0,
		'clear'     => 0,
		'clear_off' => 0,
		'mtime'     => 0,
		'gui'       => 0,
		'playing'   => 0,
	);
	if ($tmp{'type'} =~ /\bSTATUS\b/i) {
		$attr{'status'} = 1;
		$attr{'mtime'}  = 1;
	}
	if ($tmp{'type'} =~ /\bEXISTS\b/i) {
		$attr{'exists'} = 1;
		$attr{'mtime'}  = 1;
	}
	if ($tmp{'type'} =~ /\bVALUE\b/i) {
		$attr{'status'} = 1;
		$attr{'value'}  = 1;
		$attr{'mtime'}  = 1;
	}
	if ($tmp{'type'} =~ /\bCLEAR\b/i) {
		$attr{'clear'} = 1;
	}
	if ($tmp{'type'} =~ /\bON\b/i) {
		$attr{'clear_off'} = 1;
	}
	if ($tmp{'type'} =~ /\bMTIME\b/i) {
		$attr{'mtime'} = 1;
	}
	if ($tmp{'type'} =~ /\bGUI\b/i) {
		$attr{'status'} = 1;
		$attr{'gui'}    = 1;
	}
	if ($tmp{'type'} =~ /\bPLAYING\b/i) {
		$attr{'status'}  = 1;
		$attr{'playing'} = 1;
	}
	$tmp{'attr'} = \%attr;

	# Push a hash ref
	$files{$file} = \%tmp;
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
my $state      = 'INIT';
my $stateLast  = $state;
my $status     = '';
my $statusLast = $status;
my $updateLast = 0;
my $pushLast   = 0;

# Loop forever
while (1) {

	# Provide a method to force updates even when the state does not change
	my $update = 0;

	# Check for queued commands
	my @ready_clients = $select->can_read($DELAY);
	foreach my $fh (@ready_clients) {

		# Grab the inbound text
		my $path = undef();
		$fh->recv($path, $MAX_CMD_LEN);
		$path =~ s/^\s+//;
		$path =~ s/\s+$//;
		if ($DEBUG) {
			print STDERR 'Got path: ' . $path . "\n";
		}

		# Only accept valid paths
		if (!-r $path) {
			print STDERR 'Invalid socket path: ' . $path . "\n";
			next;
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

		# Force an update
		$update = 1;
	}

	# Use opendir/readdir in each folder to ensure fresh results
	my %folders = ();
	foreach my $file (values(%files)) {
		if (!$folders{ $file->{'dir'} }) {
			my $dh = undef();
			if (opendir($dh, $file->{'dir'})) {
				if ($DEBUG) {
					print STDERR 'Refreshed folder: ' . $file->{'dir'} . "\n";
				}
				my @files = readdir($dh);
				closedir($dh);
			}
			$folders{ $file->{'dir'} } = 1;
		}
	}

	# Monitor files of all types
	foreach my $file (values(%files)) {

		# Skip "NONE" files -- they are data stores handled in other actions
		if ($file->{'type'} eq 'NONE') {
			next;
		}

		# Always record the previous status and clear the new one
		$file->{'last'}  = $file->{'value'};
		$file->{'value'} = 0;

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
					$file->{'update'} = time();
				}
			} else {
				$file->{'update'} = $mtime;
			}

			if ($DEBUG) {
				print STDERR 'Mtime: ' . $file->{'name'} . ': ' . $file->{'value'} . ':' . $file->{'update'} . "\n";
			}
		}

		# Grab the state from STATUS files
		if ($file->{'attr'}->{'status'}) {
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
				$text =~ s/\n$//;
				$file->{'value'} = $text;
			} elsif ($file->{'attr'}->{'playing'}) {
				if ($text =~ /PlayStatus\:Playing/) {
					$file->{'value'} = 1;
				}
			} elsif ($file->{'attr'}->{'gui'}) {
				if (!($text =~ /ActiveWindowName\:Fullscreen video/)) {
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
						print STDERR 'Status (extra): ' . $name . ': ' . $files{$name}{'value'} . "\n";
					}
				}
			}
		}
	}

	# Set the global update timestamp
	foreach my $file (values(%files)) {
		if ($file->{'update'} > $updateLast) {
			$updateLast = $file->{'update'};
		}
	}

	# Calculate the new state
	$stateLast = $state;
	if ($DISPLAY && exists($files{$DISPLAY}) && $files{$DISPLAY}->{'value'}) {

		# We are always either playing or paused if the display is on
		# When we're playing "Audio" assume we are paused
		if (   (exists($files{'PLAYING'}) && $files{'PLAYING'}->{'value'})
			&& ((exists($files{'PLAYING_TYPE'}) && $files{'PLAYING_TYPE'}->{'value'} ne 'Audio') || !exists($files{'PLAYING_TYPE'})))
		{
			$state = 'PLAY';
		} else {
			$state = 'PAUSE';
		}

	} else {

		# If the display is off, check the timeouts
		my $timeSinceUpdate = time() - $updateLast;
		if ($timeSinceUpdate > $STATE_TIMEOUT) {
			$state = 'OFF';
		} elsif ($timeSinceUpdate < $STATE_TIMEOUT) {
			if (exists($files{'NO_MOTION'}) && $files{'NO_MOTION'}->{'value'}) {
				$state = 'OFF';
			} else {
				$state = 'MOTION';
			}
		}
	}
	if ($state eq 'INIT') {
		$state = 'OFF';
	}

	# Clear EXISTS_ON files when the main state is "OFF" (and before we append their status)
	foreach my $file (values(%files)) {
		if ($file->{'attr'}->{'clear_off'} && $file->{'value'} && $state eq 'OFF') {
			unlink($file->{'path'});
			$file->{'stauts'} = 0;
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
			$file->{'stauts'} = 0;
			if ($DEBUG) {
				print STDERR 'Clearing exists flag for: ' . $file->{'name'} . "\n";
			}
		}
	}

	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		$update = 1;
	}

	# Update on any status change
	foreach my $file (values(%files)) {
		if ($file->{'value'} ne $file->{'last'}) {
			$update = 1;
			last;
		}
	}

	# Force updates on any state change
	if ($stateLast ne $state || $statusLast ne $status) {
		if ($DEBUG) {
			print STDERR 'State change: ' . $stateLast . $statusLast . ' => ' . $state . $status . "\n";
		}
		$update = 1;
	}

	# Push the update
	if ($update) {

		# Note the push
		$pushLast = time();

		# Send notifications to all subscribers
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
