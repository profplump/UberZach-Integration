#!/usr/bin/perl
use strict;
use warnings;
use File::Basename;
use IPC::System::Simple;

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;
use Audio;

# User config
my $MEDIA_PATH = `~/bin/video/mediaPath`;
my %FILES      = ();

# Prototypes
sub init();
sub load($$);
sub unload($);
sub stop();
sub printFiles();
sub dieUnloaded($);

# App config
my $DATA_DIR    = DMX::dataDir();
my $OUTPUT_FILE = $DATA_DIR . 'QT_PLAYER';
my $STATE_SOCK  = $OUTPUT_FILE . '.socket';
my $DELAY       = 5;
my $MAX_CMD_LEN = 16384;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Clear our output file
if (-e $OUTPUT_FILE) {
	unlink($OUTPUT_FILE);
}

# Reset QT Player
init();

# Sockets
my $SELECT = DMX::selectSock($STATE_SOCK);

# Loop forever
while (1) {

	# Wait for commands
	{
		my @ready_clients = $SELECT->can_read($DELAY);
		foreach my $fh (@ready_clients) {

			# Ensure we won't block on recv()
			$fh->blocking(0);

			# Read
			while (defined($fh->recv(my $text, $MAX_CMD_LEN))) {

				# Parse
				my @argv = split(/\|/, $text);

				# Ignore empty commands
				if (scalar(@argv) < 1) {
					next;
				}

				# Dispatch commands
				my $cmd = shift(@argv);
				if ($cmd eq 'LOAD' && scalar(@argv) == 2) {
					load($argv[0], $argv[1]);
				} elsif ($cmd eq 'UNLOAD' && scalar(@argv) == 1) {
					unload($argv[0]);
				} elsif ($cmd eq 'STOP') {
					stop();
				} elsif ($cmd eq 'RESET') {
					init();
				} else {
					warn('Ignored invalid command: ' . $text . "\n");
				}
			}
		}
	}

	# Keep our list of files in-sync with reality
	foreach my $name (keys(%FILES)) {
		eval { Audio::runApplescript('tell application "QuickTime Player" to get document ' . $FILES{$name}); };
		if ($@) {
			warn('File went missing: ' . $name . "\n");
			delete($FILES{$name});
			printFiles();
		}
	}

	# Ensure "silence" is always available -- reset if it goes away
	if (!exists($FILES{'SILENCE'})) {
		init();
	}
}

# Get things into a reasonable state
sub init() {
	if ($DEBUG) {
		print STDERR "init()\n";
	}

	# Reset our local state
	%FILES = ();

	# Close all QT documents and relaunch QT Player
	Audio::runApplescript('tell application "QuickTime Player" to close every document');
	Audio::runApplescript('tell application "QuickTime Player" to quit');
	sleep(1);
	IPC::System::Simple::system('open', '-a', 'QuickTime Player');

	# Always load and play the SILENCE file (for sanity and general init)
	load('SILENCE', 'DMX/Silence.wav');

	# Bring Plex back to the front
	Audio::runApplescript('tell application "Plex" to activate');
}

# Open the named file and record the handle
sub load($$) {
	my ($name, $path) = @_;
	if ($DEBUG) {
		print STDERR 'load(): ' . $name . ', ' . $path . "\n";
	}

	# Build a reasonable path
	if (!($path =~ /^\//)) {
		$path = $MEDIA_PATH . '/' . $path;
	}

	# Ensure the file exists
	if (!-r $path) {
		warn('Invalid audio file path: ' . $path . "\n");
		return;
	}

	# Ignore duplicate loads
	if (exists($FILES{$name})) {
		warn('Ignoring load request for existing file: ' . $name . "\n");
		return;
	}

	# Find out how many files are already open
	my $count = Audio::runApplescript('tell application "QuickTime Player" to count items of every document');

	# Open the file
	# It would be nice to use AppleScript here, so we can get a more definitive name, but the open() call is borked
	IPC::System::Simple::system('open', '-a', 'QuickTime Player', $path);

	# Wait for QT to load the new file
	# To avoid indefinate hangs this will give up after 5 seconds. When it does the results are undefined.
	my @cmd = ('tell application "QuickTime Player"');
	push(@cmd, 'set endDate to current date + (5/60 * minutes)');
	push(@cmd, 'repeat while (count items of every document) <= ' . $count . ' and current date < endDate');
	push(@cmd, 'delay 0.1');
	push(@cmd, 'end repeat');
	push(@cmd, 'get document 1');
	push(@cmd, 'end tell');
	my $doc = Audio::runApplescript(join("\n", @cmd));

	# Clean up the document name
	$doc =~ s/^\s*document //;
	$doc =~ s/\s+$//;
	$doc =~ s/\"/\\\"/g;
	$doc = '"' . $doc . '"';

	# Save the document handle
	$FILES{$name} = $doc;
	printFiles();

	# Bring Plex back to the front
	Audio::runApplescript('tell application "Plex" to activate');
}

# Close the named file
sub unload($) {
	my ($name) = @_;
	if ($DEBUG) {
		print STDERR 'unload(): ' . $name . "\n";
	}

	# Ignore files that don't exist
	if (!exists($FILES{$name})) {
		warn('No such file loaded: ' . $name . "\n");
		return;
	}

	# Close to document
	Audio::runApplescript('tell application "QuickTime Player" to close document ' . $FILES{$name});

	# Delete our handle
	delete($FILES{$name});
	printFiles();
}

# Stop and rewind all QT documents
sub stop() {
	Audio::runApplescript('tell application "QuickTime Player" to stop every document');
	Audio::runApplescript('tell application "QuickTime Player" to set current time of every document to 0');
}

# Update the output file list
sub printFiles() {
	my ($fh, $tmp) = File::Temp::tempfile($OUTPUT_FILE . '.XXXXXXXX', 'UNLINK' => 0);
	foreach my $file (keys(%FILES)) {
		print $fh $file . '|' . $FILES{$file} . "\n";
	}
	close($fh);
	rename($tmp, $OUTPUT_FILE);
}
