#!/usr/bin/perl
use strict;
use warnings;
use POSIX;
use File::Touch;
use File::Basename;
use Time::HiRes qw( usleep sleep time );
use IPC::System::Simple qw( system capture );

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

# Always load the SILENCE file (also serves as a sanity check)
audioLoad('SILENCE', 'DMX/Silence.wav');

sub runApplescript($) {
	my ($script) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript: ' . $script . "\n";
	}

	my $retval = capture('osascript', '-e', $script);
	if ($DEBUG) {
		print STDERR "\tAppleScript result: " . $retval . "\n";
	}

	return $retval;
}

sub audioAdd($$) {
	my ($name, $path) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript::audioAdd(): ' . $name . "\n";
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
	audioDrop($name);

	# Append the array
	my %tmp = ('path' => $path);
	$FILES{$name} = \%tmp;
}

sub audioDrop($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript::dropAudio(): ' . $name . "\n";
	}

	# Unload as necessary
	if (audioLoaded($name)) {
		audioStop($name);
		audioUnload($name);
	}

	# Drop as necessary
	if (audioExists($name)) {
		delete($FILES{$name});
	}
}

sub audioLoaded($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript::audioLoaded(): ' . $name . "\n";
	}

	if (audioExists($name) && defined($FILES{$name}->{'name'})) {
		return 1;
	}
	return 0;
}

sub audioExists($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript::audioExists(): ' . $name . "\n";
	}

	if (defined($name) && defined($FILES{$name})) {
		return 1;
	}
	return 0;
}

sub audioPlay($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript::playAudio(): ' . $name . "\n";
	}

	# Start playback
	audioBackground($name);

	# Wait for it to complete
	my @cmd = ('tell application "QuickTime Player"');
	push(@cmd, 'repeat while playing of document ' . $FILES{$name}->{'name'} . ' = true');
	push(@cmd, 'delay 0.05');
	push(@cmd, 'end repeat');
	push(@cmd, 'end tell');
	runApplescript(join("\n", @cmd));
}

sub audioBackground($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript::playAudio(): ' . $name . "\n";
	}
	if (!audioLoaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Start playback
	my @cmd = ('tell application "QuickTime Player"');
	push(@cmd, 'set current time of document ' . $FILES{$name}->{'name'} . ' to 0');
	push(@cmd, 'play document ' . $FILES{$name}->{'name'});
	push(@cmd, 'end tell');
	runApplescript(join("\n", @cmd));
}

sub audioPlaying($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript::audioPlaying(): ' . $name . "\n";
	}
	if (!audioLoaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Ask QT if the document is playing
	my $result = runApplescript('tell application "QuickTime Player" to get playing of document ' . $FILES{$name}->{'name'});
	if ($result =~ /true/i) {
		return 1;
	}
	return 0;
}

sub audioPosition($$) {
	my ($name, $new) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript::audioPosition(): ' . $name . "\n";
	}
	if (!audioLoaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Optionally set the audio position
	if ($new) {
		runApplescript('tell application "QuickTime Player" to set current time of document ' . $FILES{$name}->{'name'} . ' to ' . $new);
	}

	# Get the current playback position from QT
	return runApplescript('tell application "QuickTime Player" to get current time of document ' . $FILES{$name}->{'name'});
}

sub audioRate($$) {
	my ($name, $new) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript::audioRate(): ' . $name . "\n";
	}
	if (!audioLoaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Optionally set the playback rate
	if ($new) {
		runApplescript('tell application "QuickTime Player" to set rate of document ' . $FILES{$name}->{'name'} . ' to ' . $new);
	}

	# Get the current playback position from QT
	return runApplescript('tell application "QuickTime Player" to get rate of document ' . $FILES{$name}->{'name'});
}

sub audioStop($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR "AppleScript::stopAudio()\n";
	}

	# Allow control of all documents or a specific document
	my $doc = 'every document';
	if (!audioLoaded($name)) {
		$doc = 'document ' . $FILES{$name}->{'name'};
	}

	# Stop and rewind all QT documents
	runApplescript('tell application "QuickTime Player" to stop ' . $doc);
	runApplescript('tell application "QuickTime Player" to set current time of ' . $doc . ' to 0');

	# Bring Plex back to the front
	runApplescript('tell application "Plex" to activate');
}

sub audioUnload($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'AppleScript::loadAudio(): ' . $name . "\n";
	}
	if (!audioExists($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	# Nothing to do if the file isn't loaded
	if (!audioLoaded($name)) {
		return;
	}

	# Close to document
	runApplescript('tell application "QuickTime Player" to close document ' . $FILES{$name}->{'name'});
}

sub audioLoad($) {
	my ($name) = @_;
	if (!audioExists($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}
	if ($DEBUG) {
		print STDERR 'AppleScript::loadAudio(): ' . $name . "\n";
	}

	# Unload first, if we're already loaded
	if (audioLoaded($name)) {
		audioUnload($name);
	}

	# Find out how many files are already open
	my $count = runApplescript('tell application "QuickTime Player" to count items of every document');

	# Open the file
	system('open', '-a', 'QuickTime Player', $file);

	# Wait for QT to load the new file
	my @cmd = ('tell application "QuickTime Player"');
	push(@cmd, 'repeat while (count items of every document) <= ' . $count);
	push(@cmd, 'delay 0.05');
	push(@cmd, 'end repeat');
	push(@cmd, 'get document 1');
	push(@cmd, 'end tell');
	my $doc = runApplescript(join("\n", @cmd));

	# Clean up the document name
	$doc =~ s/^\s*document //;
	$doc =~ s/\s+$//;
	$doc =~ s/\"/\\\"/g;
	$doc = '"' . $doc . '"';
	return $doc;
}

# Always return true
1;
