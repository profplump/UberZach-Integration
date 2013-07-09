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

# Config
my $DISPLAY  = 1;
my %PROFILES = (
	'HIGH' => 'Epson-High',
	'PLAY' => 'Epson-Theater',
	'LOW'  => 'Epson-Theater_Black',
);

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'COLOR';
my $STATE_SOCK   = $OUTPUT_FILE . '.socket';
my $PUSH_TIMEOUT = 20;
my $PULL_TIMEOUT = $PUSH_TIMEOUT * 3;
my $DELAY        = $PULL_TIMEOUT / 2;

# Prototypes
sub runApplescript($);
sub getProfile($);
sub setProfile($$);
sub profileExists($$);

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
my $color     = 'OFF';
my $colorLast = $color;
my %exists    = ();
my $pushLast  = 0;
my $pullLast  = time();
my $update    = 0;

# Validate our profiles
foreach my $profile (keys(%PROFILES)) {
	if (!profileExists($DISPLAY, $PROFILES{$profile})) {
		die('Invalid profile: ' . $profile . ' => ' . $PROFILES{$profile} . "\n");
	}
}

# Loop forever
while (1) {

	# Grab the current color profile
	$colorLast = $color;
	$color     = getProfile($DISPLAY);

	# If the color profile has changed, save the state to disk
	if ($colorLast ne $color) {
		if ($DEBUG) {
			print STDERR 'New color profile: ' . $colorLast . ' => ' . $color . "\n";
		}
		my ($fh, $tmp) = tempfile($OUTPUT_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $color . "\n";
		close($fh);
		rename($tmp, $OUTPUT_FILE);
	}

	# State is calculated; use newState to gather data
	my $newState = $state;

	# Wait for state updates
	my $cmdState = DMX::readState($DELAY, \%exists, undef(), undef());
	if (defined($cmdState)) {
		$newState = $cmdState;
		$pullLast = time();
	}

	# Die if we don't see regular updates
	if (time() - $pullLast > $PULL_TIMEOUT) {
		die('No update on state socket in past ' . $PULL_TIMEOUT . " seconds. Exiting...\n");
	}

	# Calculate the new state
	$stateLast = $state;
	if ($exists{'PROJECTOR_COLOR'} eq 'DYNAMIC') {
		$state = 'HIGH';
	} elsif ($exists{'PROJECTOR_COLOR'} eq 'THEATER') {
		$state = 'PLAY';
	} else {
		$state = 'LOW';
	}

	# Force updates on a periodic basis
	if (!$update && time() - $pushLast > $PUSH_TIMEOUT) {

		# Not for the color profile
		#if ($DEBUG) {
		#	print STDERR "Forcing periodic update\n";
		#}
		#$update = 1;
	}

	# Force updates when there is a physical state mistmatch
	if (!$update && $PROFILES{$state} ne $color) {
		if ($DEBUG) {
			print STDERR 'State mismatch: ' . $color . ' => ' . $PROFILES{$state} . "\n";
		}
		$update = 1;
	}

	# Update the color profile
	if ($update) {

		# Update
		if ($DEBUG) {
			print STDERR 'Setting output to: ' . $PROFILES{$state} . "\n";
		}
		setProfile($DISPLAY, $PROFILES{$state});

		# Update the push time
		$pushLast = time();

		# Clear the update flag
		$update = 0;
	}
}

sub runApplescript($) {
	my ($script) = @_;
	if ($DEBUG) {
		print STDERR 'Running AppleScript: ' . $script . "\n";
	}

	my $retval = capture('osascript', '-e', $script);
	if ($DEBUG) {
		print STDERR "\tAppleScript result: " . $retval . "\n";
	}

	return $retval;
}

sub getProfile($) {
	my ($display) = @_;
	if ($DEBUG) {
		print STDERR "getProfile()\n";
	}

	# Validate the input
	$display = int($display);
	if (!$display) {
		die('Invalid display ID: ' . $display . "\n");
	}

	# Ask SwitchResX what color profile is installed
	my $profile = runApplescript('tell application "SwitchResX Daemon" to get display profile of display ' . $display);

	# Cleanup the name
	$profile =~ s/^\s*profile //;
	$profile =~ s/\s+$//;

	return $profile;
}

sub setProfile($$) {
	my ($display, $profile) = @_;
	if ($DEBUG) {
		print STDERR "setProfile()\n";
	}

	# Validate the input
	$profile =~ s/\"/\\\"/g;
	$profile = '"' . $profile . '"';
	$display = int($display);
	if (!$display) {
		die('Invalid display ID: ' . $display . "\n");
	}

	# Tell SwitchResX to change our color profile
	my @cmd = ('tell application "SwitchResX Daemon"');
	push(@cmd, 'set prof to profile ' . $profile . ' of display ' . $display);
	push(@cmd, 'set display profile of display ' . $display . ' to prof');
	push(@cmd, 'end tell');

	return runApplescript(join("\n", @cmd));
}

sub profileExists($$) {
	my ($display, $profile) = @_;
	if ($DEBUG) {
		print STDERR "profileExists()\n";
	}

	# Validate the input
	$profile =~ s/\"/\\\"/g;
	$profile = '"' . $profile . '"';
	$display = int($display);
	if (!$display) {
		die('Invalid display ID: ' . $display . "\n");
	}

	# Ask SwitchResX if the named color profile exists
	my @cmd = ('tell application "SwitchResX Daemon"');
	push(@cmd, 'set profs to get name of every profile of display ' . $display);
	push(@cmd, 'get profs contains ' . $profile);
	push(@cmd, 'end tell');

	my $result = runApplescript(join("\n", @cmd));
	if ($result =~ /true/i) {
		return 1;
	}
	return 0;
}
