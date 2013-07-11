#!/usr/bin/perl
use strict;
use warnings;
use POSIX;
use File::Basename;
use IPC::System::Simple;
use Time::HiRes qw( usleep sleep time );

# Package name
package Audio;

# Config
my $MEDIA_PATH = `~/bin/video/mediaPath`;

# App config
my $DATA_DIR   = DMX::dataDir();
my $QT_FILE    = $DATA_DIR . 'QT_PLAYER';
my $QT_SOCK    = $QT_FILE . '.socket';
my $WAIT_DELAY = 0.1;
my $MAX_WAIT   = 5 / $WAIT_DELAY;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# State
my %FILES = ();
my $SOCK  = undef();

# Send the provided arguments to the QT socket
sub sendCmd(@) {

	# Connect the socket as needed
	if (!$SOCK) {
		$SOCK = DMX::clientSock($QT_SOCK);
	}

	# Ensure the data is compatible with the encoding scheme
	foreach my $part (@_) {
		if ($part =~ /\|/) {
			die('Invalid QT command component: ' . $part . "\n");
		}
	}

	# Build the command stirng
	my $str = join('|', @_);
	if ($DEBUG) {
		print STDERR 'Sending QT_PLAYER command: ' . $str . "\n";
	}

	# Send the command
	$SOCK->send($str)
	  or die("Unable to send to QT socket\n");
}

# Execute the provided string with osascript
sub runApplescript($) {
	my ($script) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript: ' . $script . "\n";
	}

	my $retval = IPC::System::Simple::capture('osascript', '-e', $script);
	$retval =~ s/[\r\n]$//;
	if ($DEBUG) {
		print STDERR "\tAppleScript result: " . $retval . "\n";
	}

	return $retval;
}

# Is the named document loaded?
sub loaded($) {
	my ($name) = @_;
	parseList();
	return exists($FILES{$name});
}

# Load a document
sub load($$) {
	my ($name, $path) = @_;

	# Unload as needed
	if (loaded($name)) {
		unload($name);
	}

	# Request load
	sendCmd('LOAD', $name, $path);

	# Wait for the load to register
	my $count = 0;
	while (!loaded($name)) {
		Time::HiRes::sleep($WAIT_DELAY);
		$count++;
		if ($count > $MAX_WAIT) {
			die('Unable to open file: ' . $name . "\n");
		}
	}
}

# Unload the named document
sub unload($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::loadAudio(): ' . $name . "\n";
	}

	# Request unload
	sendCmd('UNLOAD', $name);

	# Wait for the unload to register
	my $count = 0;
	while (loaded($name)) {
		Time::HiRes::sleep($WAIT_DELAY);
		$count++;
		if ($count > $MAX_WAIT) {
			die('Unable to close file: ' . $name . "\n");
		}
	}
}

# Play the named document, waiting for completion
sub play($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::play(): ' . $name . "\n";
	}

	# Ensure the file is loaded
	dieUnloaded($name);

	my @cmd = ('tell application "QuickTime Player"');
	push(@cmd, 'play document ' . $FILES{$name});
	push(@cmd, 'repeat while playing of document ' . $FILES{$name} . ' = true');
	push(@cmd, 'delay 0.1');
	push(@cmd, 'end repeat');
	push(@cmd, 'end tell');
	runApplescript(join("\n", @cmd));
}

# Play the named document and immediately return
sub background($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::background(): ' . $name . "\n";
	}

	# Ensure the file is loaded
	dieUnloaded($name);

	runApplescript('tell application "QuickTime Player" to play document ' . $FILES{$name});
}

# Pause the named document
sub pause($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::pause(): ' . $name . "\n";
	}

	# Ensure the file is loaded
	dieUnloaded($name);

	runApplescript('tell application "QuickTime Player" to pause document ' . $FILES{$name});
}

# Stop playback of the named document
sub stop($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR "Audio::stopAudio()\n";
	}

	# Ensure the file is loaded
	dieUnloaded($name);

	# Stop and rewind
	runApplescript('tell application "QuickTime Player" to stop document ' . $FILES{$name});
	runApplescript('tell application "QuickTime Player" to set current time of document ' . $FILES{$name} . ' to 0');
}

# Is the named document playing?
sub playing($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::playing(): ' . $name . "\n";
	}

	# Ensure the file is loaded
	dieUnloaded($name);

	# QT has a "playing" property but it is only true when rate == 1.0
	my $rate = rate($name);
	if ($rate > 0) {
		return 1;
	}
	return 0;
}

# Set or get the audio position
sub position($$) {
	my ($name, $new) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::position(): ' . $name . "\n";
	}

	# Ensure the file is loaded
	dieUnloaded($name);

	if ($new) {
		runApplescript('tell application "QuickTime Player" to set current time of document ' . $FILES{$name} . ' to ' . $new);
	} else {
		return runApplescript('tell application "QuickTime Player" to get current time of document ' . $FILES{$name});
	}
}

# Set or get the playback rate
sub rate($$) {
	my ($name, $new) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::rate(): ' . $name . "\n";
	}

	# Ensure the file is loaded
	dieUnloaded($name);

	if ($new) {
		runApplescript('tell application "QuickTime Player" to set rate of document ' . $FILES{$name} . ' to ' . $new);
	} else {
		return runApplescript('tell application "QuickTime Player" to get rate of document ' . $FILES{$name});
	}
}

# Set or get a document's volume
sub volume($$) {
	my ($name, $new) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::volume(): ' . $name . "\n";
	}

	# Ensure the file is loaded
	dieUnloaded($name);

	if ($new) {
		runApplescript('tell application "QuickTime Player" to set audio volume of document ' . $FILES{$name} . ' to ' . $new);
	} else {
		return runApplescript('tell application "QuickTime Player" to get audio volume of document ' . $FILES{$name});
	}
}

# Set or get the system output volume
sub systemVolume($) {
	my ($new) = @_;
	if ($DEBUG) {
		print STDERR "Audio::systemVolume()\n";
	}

	if ($new) {
		runApplescript('set volume output volume ' . $new);
	} else {
		return runApplescript('get output volume of (get volume settings)');
	}
}

# Stop playback on all documents
sub stopAll() {
	sendCmd('STOP');
}

# Reset the entire QT Player process
sub reset() {
	sendCmd('RESET');
}

# Read and parse the qt_player file list
sub parseList() {
	%FILES = ();
	open(my $fh, $QT_FILE)
	  or die('Unable to open QT_PLAYER file: ' . $! . "\n");
	while (<$fh>) {
		my ($name, $handle) = $_ =~ /^([^|]+)\|\s*(\".+\")\s*$/;
		if (!$name || !$handle) {
			die('Invalid QT_PLAYER line: ' . $_);
		}
		$FILES{$name} = $handle;
	}
	close($fh);
}

sub dieUnloaded($) {
	my ($name) = @_;
	if (!loaded($name)) {
		die('File not loaded: ' . $name . "\n");
	}
}

# Always return true
1;
