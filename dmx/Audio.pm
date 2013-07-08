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

# Set or get a document's volume
sub volume($$) {
	my ($name, $new) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::volume(): ' . $name . "\n";
	}
	if (!loaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	if ($new) {
		runApplescript('tell application "QuickTime Player" to set audio volume of document ' . $FILES{$name}->{'name'} . ' to ' . $new);
	} else {
		return runApplescript('tell application "QuickTime Player" to get audio volume of document ' . $FILES{$name}->{'name'});
	}
}

# Add an load a document
sub addLoad($$) {
	my ($name, $path) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::addLoad(): ' . $name . "\n";
	}
	add($name, $path);
	load($name);
}

# Add a document to the available list
sub add($$) {
	my ($name, $path) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::add(): ' . $name . ', ' . $path . "\n";
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

# Drop a document from the available list, unloaded as necessary
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

# Is the named document loaded?
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

# Is the named document configured?
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

# Play the named document, waiting for completion
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

# Play the named document and immediately return
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

# Is the named document playing?
sub playing($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::playing(): ' . $name . "\n";
	}

	# Ask QT if the document is playing
	# Note that while QT has a "playing" property it is only true when rate == 1.0
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
	if (!loaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	if ($new) {
		runApplescript('tell application "QuickTime Player" to set current time of document ' . $FILES{$name}->{'name'} . ' to ' . $new);
	} else {
		return runApplescript('tell application "QuickTime Player" to get current time of document ' . $FILES{$name}->{'name'});
	}
}

# Set or get the playback rate
sub rate($$) {
	my ($name, $new) = @_;
	if ($DEBUG) {
		print STDERR 'Audio::rate(): ' . $name . "\n";
	}
	if (!loaded($name)) {
		die('Invalid QT document: ' . $name . "\n");
	}

	if ($new) {
		runApplescript('tell application "QuickTime Player" to set rate of document ' . $FILES{$name}->{'name'} . ' to ' . $new);
	} else {
		return runApplescript('tell application "QuickTime Player" to get rate of document ' . $FILES{$name}->{'name'});
	}
}

# Pause the named document
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

# Stop playback of the named document or all documents
sub stop($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR "Audio::stopAudio()\n";
	}

	# Allow control of all documents or a specific document
	my $doc = 'every document';
	if (loaded($name)) {
		$doc = 'document ' . $FILES{$name}->{'name'};
	}

	# Stop and rewind all QT documents
	runApplescript('tell application "QuickTime Player" to stop ' . $doc);
	runApplescript('tell application "QuickTime Player" to set current time of ' . $doc . ' to 0');

	# Bring Plex back to the front
	runApplescript('tell application "Plex" to activate');
}

# Unload the named document
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

# Load the named document
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
	push(@cmd, 'set endDate to current date + (3/60 * minutes)');
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

# Get things into a reasonable state
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
