#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket;
use Time::HiRes qw( usleep );
use File::Temp qw( tempfile );

# Prototypes
sub dim($);

# User config
my %DIM = (
	'OFF'    => [
		{ 'channel' => 11, 'value' => 0,   'time' => 0 }
	],
	'ON'    => [
		{ 'channel' => 11, 'value' => 255, 'time' => 0 }
	],
);

# App config
my $SOCK_TIMEOUT = 5;
my $TEMP_DIR     = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR     = $TEMP_DIR . 'plexMonitor/';
my $CMD_FILE     = $DATA_DIR . 'DMX.socket';
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
$DELAY *= 1000000;    # Microseconds;

# Sanity check
if (!-d $DATA_DIR || !-S $CMD_FILE) {
	die("Bad config\n");
}

# Socket init
my $sock = IO::Socket::UNIX->new(
	'Peer'    => $CMD_FILE,
	'Type'    => SOCK_DGRAM,
	'Timeout' => $SOCK_TIMEOUT
) or die('Unable to open socket: ' . $CMD_FILE . ": ${@}\n");

# State
my $state     = 'INIT';
my $stateLast = $state;
my $fan       = 0;
my $projector = 0;
my $pushLast  = 0;

# Always force lights out at launch
dim({ 'channel' => 11, 'value' => 0, 'time' => 0 });

# Loop forever
while (1) {

	# Set anywhere to force an update this cycle
	my $forceUpdate = 0;

	# Monitor the PROJECTOR file for state
	{
		$projector = 0;
		my $fh;
		open($fh, $DATA_DIR . 'PROJECTOR')
		  or die("Unable to open PROJECTOR\n");
		my $text = <$fh>;
		close($fh);
		if ($text =~ /1/) {
			$projector = 1;
		}
		if ($DEBUG) {
			print STDERR 'Projector: ' . $projector . "\n";
		}
	}

	# Monitor the FAN_CMD file for presence
	{

		# Clear the flag when the projector is off
		if ($fan && !$projector) {
			unlink($DATA_DIR . 'FAN_CMD');
		}

		$fan = 0;
		if (-e $DATA_DIR . 'FAN_CMD') {
			$fan = 1;
		}
		if ($DEBUG) {
			print STDERR 'Fan: ' . $fan . "\n";
		}
	}

	# Calculate the new state
	$stateLast = $state;
	if ($fan) {
		if ($projector) {
			$state = 'ON';
		} else {
			$state = 'OFF';
		}
	} else {
		$state = 'OFF';
	}
	if ($state eq 'INIT') {
		$state = 'OFF';
	}

	# Force updates on a periodic basis
	if (time() - $pushLast > $PUSH_TIMEOUT) {
		$forceUpdate = 1;
	}

	# Update the fan state
	if ($forceUpdate || $stateLast ne $state) {
		if ($DEBUG) {
			print STDERR 'State: ' . $stateLast . ' => ' . $state . "\n";
			foreach my $data (@{ $DIM{$state} }) {
				print STDERR "\t" . $data->{'channel'} . ' => ' . $data->{'value'} . ' @ ' . $data->{'time'} . "\n";
			}
		}

		# Send the dim command
		my @values = ();
		foreach my $data (@{ $DIM{$state} }) {
			dim($data);
			push(@values, $data->{'channel'} . ' => ' . $data->{'value'} . ' @ ' . $data->{'time'});
		}

		# Save the state and value to disk
		my ($fh, $tmp) = tempfile($DATA_DIR . 'FAN.XXXXXXXX', 'UNLINK' => 0);
		print $fh 'State: ' . $state . "\n" . join("\n", @values) . "\n";
		close($fh);
		rename($tmp, $DATA_DIR . 'FAN');
		
		# Update the push time
		$pushLast = time();
	}

	# Wait and loop
	usleep($DELAY);
}

# Send the command
sub dim($) {
	my ($args) = @_;
	if (!defined($args->{'delay'})) {
		$args->{'delay'} = 0;
	}
	if (!defined($args->{'channel'}) || !defined($args->{'time'}) || !defined($args->{'value'})) {
		die('Invalid command for socket: ' . join(', ', keys(%{$args})) . ': ' . join(', ', values(%{$args})) . "\n");
	}

	my $cmd = join(':', $args->{'channel'}, $args->{'time'}, $args->{'value'}, $args->{'delay'});
	$sock->send($cmd)
	  or die('Unable to write command to socket: ' . $CMD_FILE . ': ' . $cmd . ": ${!}\n");
}
