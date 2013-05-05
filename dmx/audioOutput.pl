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

# App config
my $DATA_DIR     = DMX::dataDir();
my $OUTPUT_FILE  = $DATA_DIR . 'AUDIO_OUTPUT';
my $DELAY        = 1;
my @AUDIO_GET    = ('/Users/tv/bin/SwitchAudioSource', '-c');

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# State
my $device     = '';
my $deviceLast = $device;

# Loop forever
while (1) {

	# Save the last output device
	$deviceLast = $device;

	# Grab the current audio output device
	$device = capture(@AUDIO_GET);
	$device =~ s/\n$//;

	# If something has changed, save the state to disk
	if ($device ne $deviceLast) {
		if ($DEBUG) {
			print STDERR 'New output device: ' . $deviceLast . ' => ' . $device . "\n";
		}
		my ($fh, $tmp) = tempfile($OUTPUT_FILE . '.XXXXXXXX', 'UNLINK' => 0);
		print $fh $device . "\n";
		close($fh);
		rename($tmp, $OUTPUT_FILE);
	}

	# Wait between updates
	sleep($DELAY);
}
