#!/usr/bin/perl
use strict;
use warnings;
use POSIX;
use File::Touch;
use File::Basename;
use Time::HiRes qw( usleep sleep time );
use IPC::System::Simple;

# Package name
package Audio;

# Config
my $MEDIA_PATH = `~/bin/video/mediaPath`;
my %FILES      = ();

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

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

sub addLoad($$) {
	my ($name, $path) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::addLoad(): ' . $name . "\n";
	}
	add($name, $path);
	load($name);
}

sub add($$) {
	my ($name, $path) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::add(): ' . $name . "\n";
	}

	# Construct an absolute file path
	if (!($path =~ /^\//)) {
		$path = $MEDIA_PATH . '/' . $path;
	}

	# Validate
	if (!-r $path) {
		die('Invalid audio path: ' . $path . "\n");
	}

	# We only support one document per name
	drop($name);

	# Append the array
	my %tmp = ('path' => $path);
	$FILES{$name} = \%tmp;
}

sub drop($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::drop(): ' . $name . "\n";
	}

	# Stop and unload as necessary
	if (loaded($name)) {
		stop($name);
		unload($name);
	}

	# Drop as necessary
	if (available($name)) {
		delete($FILES{$name});
	}
}

sub loaded($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::loaded(): ' . $name . "\n";
	}

	if (available($name) && defined($FILES{$name}->{'name'})) {
		return 1;
	}
	return 0;
}

sub available($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::available(): ' . $name . "\n";
	}

	if (defined($name) && defined($FILES{$name})) {
		return 1;
	}
	return 0;
}

sub play($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::play(): ' . $name . "\n";
	}

	# Start playback
	background($name);

	# Wait for it to complete
	my @cmd = ('tell application "QuickTime Player"');
	push(@cmd, 'repeat while playing of document ' . $FILES{$name}->{'name'} . ' = true');
	push(@cmd, 'delay 0.1');
	push(@cmd, 'end repeat');
	push(@cmd, 'end tell');
	runApplescript(join("\n", @cmd));
}

sub background($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::background(): ' . $name . "\n";
	}
	if (!loaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Start playback
	runApplescript('tell application "QuickTime Player" to play document ' . $FILES{$name}->{'name'});
}

sub playing($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::playing(): ' . $name . "\n";
	}
	if (!loaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Ask QT if the document is playing
	my $result = runApplescript('tell application "QuickTime Player" to get playing of document ' . $FILES{$name}->{'name'});
	if ($result =~ /true/i) {
		return 1;
	}
	return 0;
}

sub position($$) {
	my ($name, $new) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::position(): ' . $name . "\n";
	}
	if (!loaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Optionally set the audio position
	if ($new) {
		runApplescript('tell application "QuickTime Player" to set current time of document ' . $FILES{$name}->{'name'} . ' to ' . $new);
	}

	# Get the current playback position from QT
	return runApplescript('tell application "QuickTime Player" to get current time of document ' . $FILES{$name}->{'name'});
}

sub rate($$) {
	my ($name, $new) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::rate(): ' . $name . "\n";
	}
	if (!loaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Optionally set the playback rate
	if ($new) {
		runApplescript('tell application "QuickTime Player" to set rate of document ' . $FILES{$name}->{'name'} . ' to ' . $new);
	}

	# Get the current playback position from QT
	return runApplescript('tell application "QuickTime Player" to get rate of document ' . $FILES{$name}->{'name'});
}

sub pause($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::pause(): ' . $name . "\n";
	}
	if (!loaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Pause playback
	runApplescript('tell application "QuickTime Player" to pause document ' . $FILES{$name}->{'name'});
}

sub stop($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR "Audio::stopAudio()\n";
	}

	# Allow control of all documents or a specific document
	my $doc = 'every document';
	if (!loaded($name)) {
		$doc = 'document ' . $FILES{$name}->{'name'};
	}

	# Stop and rewind all QT documents
	runApplescript('tell application "QuickTime Player" to stop ' . $doc);
	runApplescript('tell application "QuickTime Player" to set current time of ' . $doc . ' to 0');

	# Bring Plex back to the front
	runApplescript('tell application "Plex" to activate');
}

sub unload($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::loadAudio(): ' . $name . "\n";
	}
	if (!available($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Nothing to do if the file isn't loaded
	if (!loaded($name)) {
		return;
	}

	# Close to document
	runApplescript('tell application "QuickTime Player" to close document ' . $FILES{$name}->{'name'});

	# Delete our local handle
	delete($FILES{$name}->{'name'});
}

sub load($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::loadAudio(): ' . $name . "\n";
	}
	if (!available($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Unload first, if we're already loaded
	if (loaded($name)) {
		unload($name);
	}

	# Find out how many files are already open
	my $count = runApplescript('tell application "QuickTime Player" to count items of every document');

	# Open the file
	IPC::System::Simple::system('open', '-a', 'QuickTime Player', $FILES{$name}->{'path'});

	# Wait for QT to load the new file
	my @cmd = ('tell application "QuickTime Player"');
	push(@cmd, 'set endDate to current date + (0.5 * minutes)');
	push(@cmd, 'repeat while (count items of every document) <= ' . $count . ' and current date < endDate');
	push(@cmd, 'delay 0.1');
	push(@cmd, 'end repeat');
	push(@cmd, 'get document 1');
	push(@cmd, 'end tell');
	my $doc = runApplescript(join("\n", @cmd));

	# Clean up the document name
	$doc =~ s/^\s*document //;
	$doc =~ s/\s+$//;
	$doc =~ s/\"/\\\"/g;
	$doc = '"' . $doc . '"';

	# Save the document handle
	$FILES{$name}->{'name'} = $doc;

	# Bring Plex back to the front
	runApplescript('tell application "Plex" to activate');
}

sub init() {
	if ($DEBUG) {
		print STDERR "Audio::init()\n";
	}

	# Close all QT documents and relaunch QT Player
	runApplescript('tell application "QuickTime Player" to close every document');
	runApplescript('tell application "QuickTime Player" to quit');
	sleep(1);
	IPC::System::Simple::system('open', '-a', 'QuickTime Player');

	# Always load and play the SILENCE file (for sanity and general init)
	add('SILENCE', 'DMX/Silence.wav');
	load('SILENCE');
	play('SILENCE');
}

# Always return true
1;
