#!/usr/bin/perl
use strict;
use warnings;
use File::Basename;
use IPC::System::Simple;
use Time::Out qw( timeout );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;
use Audio;

# User config
my $MEDIA_PATH = `~/bin/video/mediaPath`;

# App config
my $DATA_DIR     = DMX::dataDir();
my $STATE_SOCK   = 'QT_PLAYER';
my $OUTPUT_FILE  = $DATA_DIR . $STATE_SOCK;
my $DELAY        = 5;
my $MAX_CMD_LEN  = 16384;
my $TIMEOUT_OPEN = 10;

# Globals
my %FILES = ();

# Prototypes
sub init();
sub load($$);
sub unload($);
sub stop();
sub printFiles();
sub cmdApp($$);
sub openQT($);

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Ensure the media is ready before we do anything else
if (!$MEDIA_PATH || !-d $MEDIA_PATH) {
	sleep($TIMEOUT_OPEN);
	exit(0);
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

	# Ensure the output file always exists
	if (!-r $OUTPUT_FILE) {
		printFiles();
	}

	# Ensure "silence" is always available -- reset if it goes away
	if (!exists($FILES{'SILENCE'})) {
		die("We need only the SILENCE\n");
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
	cmdApp('QuickTime Player', 'close every document');
	cmdApp('QuickTime Player', 'quit');
	sleep(1);
	openQT(undef());

	# Always load and play the SILENCE file (for sanity and general init)
	load('SILENCE', 'DMX/Silence.wav');

	# Bring OpenPHT back to the front
	cmdApp('OpenPHT', 'activate');
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
	openQT($path);

	# Wait for QT to load the new file
	# To avoid indefinate hangs this will give up after 5 seconds
	my @cmd = ('tell application "QuickTime Player"');
	push(@cmd, 'set endDate to current date + (5/60 * minutes)');
	push(@cmd, 'repeat while (count items of every document) <= ' . $count . ' and current date < endDate');
	push(@cmd, 'delay 0.1');
	push(@cmd, 'end repeat');
	push(@cmd, 'if (count items of every document) > ' . $count . ' then');
	push(@cmd, 'get document 1');
	push(@cmd, 'end if');
	push(@cmd, 'end tell');
	my $doc = Audio::runApplescript(join("\n", @cmd));

	# Reset if we cannot open -- something is out-of-sync
	if (!$doc) {
		init();
		return;
	}

	# Clean up the document name
	$doc =~ s/^\s*document //;
	$doc =~ s/\s+$//;
	$doc =~ s/\"/\\\"/g;
	$doc = '"' . $doc . '"';

	# Save the document handle
	$FILES{$name} = $doc;
	printFiles();

	# Bring OpenPHT back to the front
	cmdApp('OpenPHT', 'activate');
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

# Request the specified action from the provided app, if it's already running
sub cmdApp($$) {
	my ($app, $cmd) = @_;

	# Ask AppleScript to execute the provided command only if the specified app is already running
	my @cmd = ('tell application "System Events"');
	push(@cmd, 'if exists process "' . $app . '" then');
	push(@cmd, 'tell application "' . $app . '" to ' . $cmd);
	push(@cmd, 'end if');
	push(@cmd, 'end tell');

	# Execute
	Audio::runApplescript(join("\n", @cmd));
}

# Activate QT player, optionally loading a document
# It would be nice to use AS here to get a more definitive document name, but the open() call is QT player is borked
sub openQT($) {
	my ($doc) = @_;

	# Build the open command
	my @cmd = ('open', '-a', 'QuickTime Player');
	if ($doc) {
		push(@cmd, $doc);
	}

	# Execute, dying on timeout
	timeout $TIMEOUT_OPEN => sub {
		IPC::System::Simple::system(@cmd);
	};
	if ($@) {
		die("Open command timed out\n");
	}
}
