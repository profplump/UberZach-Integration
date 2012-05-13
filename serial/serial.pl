#!/usr/bin/perl
use strict;
use warnings;
use File::Basename;
use File::Temp qw( tempfile );
use IO::Select;
use IO::Socket::UNIX;
use Device::SerialPort;

# Prototypes
sub sendQuery($$);
sub clearBuffer($);
sub collectUntil($$);

# Device parameters
my ($DEV, $PORT, $CRLF, $DELIMITER, %CMDS, $STATUS_ON);
if (basename($0) =~ /PROJECTOR/i) {
	$DEV       = 'Projector';
	$PORT      = '/dev/tty.' . $DEV . '-DevB';
	$CRLF      = "\r\n";
	$DELIMITER = ':';
	%CMDS      = (
		'INIT'   => '',
		'ON'     => 'PWR ON',
		'OFF'    => 'PWR OFF',
		'STATUS' => 'PWR?'
	);
	$STATUS_ON = 'PWR=01';
} elsif (basename($0) =~ /AMPLIFIER/i) {
	$DEV       = 'Amplifier';
	$PORT      = '/dev/tty.' . $DEV . '-DevB';
	$CRLF      = "\r";
	$DELIMITER = "\r";
	%CMDS      = (
		'INIT'     => '',
		'ON'       => 'PWON',
		'OFF'      => 'PWSTANDBY',
		'STATUS'   => 'PW?',
		'VOL+'     => 'MVUP',
		'VOL-'     => 'MVDOWN',
		'MUTE'     => 'MUON',
		'UNMUTE'   => 'MUOFF',
		'TV'       => 'SITV',
		'DVD'      => 'SIDVD',
		'SURROUND' => 'MSDOLBY DIGITAL',
		'STEREO'   => 'MS7CH STEREO',

	);
	$STATUS_ON = 'PWON';
} elsif (basename($0) =~ /TV/i) {
	$DEV       = 'TV';
	$PORT      = '/dev/tty.' . $DEV . '-DevB';
	$CRLF      = "\r";
	$DELIMITER = "\r";
	%CMDS      = (
		'INIT'      => 'RSPW1',
		'ON'        => 'POWR1',
		'OFF'       => 'POWR0',
		'STATUS'    => 'POWR?',
		'VOL+'      => 'MVUP',
		'VOL-'      => 'MVDOWN',
		'MUTE'      => 'MUTE1',
		'UNMUTE'    => 'MUTE2',
		'TV'        => 'IAVD0',
		'PLEX'      => 'IAVD7',
		'VOL_CHECK' => 'VOLM?',
		'VOL6'      => 'VOLM6',
		'VOL12'     => 'VOLM12',
		'VOL24'     => 'VOLM24',
		'VOL+'      => 'VOLM',
		'VOL-'      => 'VOLM'
	);
	$STATUS_ON = '1';
} else {
	die("No device specified\n");
}

# App config
my $DELAY_STATUS    = 5;
my $BYTE_TIMEOUT    = 50;
my $SILENCE_TIMEOUT = $BYTE_TIMEOUT * 10;
my $MAX_CMD_LEN     = 1024;
my $BT_CHECK        = $ENV{'HOME'} . '/bin/btcheck';
my $TEMP_DIR        = `getconf DARWIN_USER_TEMP_DIR`;
chomp($TEMP_DIR);
my $DATA_DIR = $TEMP_DIR . 'plexMonitor/';
my $CMD_FILE = $DATA_DIR . uc($DEV) . '.socket';

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = 1;
}

# Command-line arguments
my ($DELAY) = @ARGV;
if (!$DELAY) {
	$DELAY = 15;
}

# Sanity check
if (!-r $PORT || !-d $DATA_DIR) {
	die("Bad config\n");
}

# Wait for the serial port to become available
system($BT_CHECK, $DEV);
if ($? != 0) {
	sleep($DELAY_STATUS);
	die('Bluetooth device "' . $DEV . "\" not available\n");
}

# Socket init
if (-e $CMD_FILE) {
	unlink($CMD_FILE);
}
my $sock = IO::Socket::UNIX->new(
	'Local' => $CMD_FILE,
	'Type'  => SOCK_DGRAM
) or die('Unable to open socket: ' . $CMD_FILE . ": ${@}\n");
if (!-S $CMD_FILE) {
	die('Failed to create socket: ' . $CMD_FILE . "\n");
}
my $select = IO::Select->new($sock)
  or die('Unable to select socket: ' . $CMD_FILE . ": ${!}\n");

# Port init
my $port = new Device::SerialPort($PORT)
  or die('Unable to open serial connection: ' . $PORT . ": ${!}\n");
$port->read_const_time($BYTE_TIMEOUT);

# Init (clear any previous state)
sendQuery($port, $CMDS{'INIT'});

# Track the power state
# Check for new commands
my $power      = -1;
my $powerLast  = $power;
my $lastStatus = 0;
while (1) {

	# Calculate our next timeout
	# Hold on select() but not more than $DELAY_STATUS after our last update
	# Plus 1 because we aren't using hi-res time
	my $timeout = ($lastStatus + $DELAY_STATUS + 1) - time();
	if ($timeout < 1) {
		$timeout = 0;
	}
	if ($DEBUG) {
		print STDERR 'Waiting for commands with timeout: ' . $timeout . "\n";
	}

	# Check for queued commands
	my @ready_clients = $select->can_read($timeout);
	foreach my $fh (@ready_clients) {

		# Grab the inbound text
		my $text = undef();
		$fh->recv($text, $MAX_CMD_LEN);
		$text =~ s/^\s+//;
		$text =~ s/\s+$//;
		if ($DEBUG) {
			print STDERR 'Got command: ' . $text . "\n";
		}

		# Only accept valid commands
		my $cmd = undef();
		foreach my $name (keys(%CMDS)) {
			if ($name eq $text) {
				$cmd = $name;
				last;
			}
		}

		# Send command to serial device
		if ($cmd) {
			if ($DEBUG) {
				print STDERR 'Sending command: ' . $cmd . "\n";
			}
			my $result = sendQuery($port, $CMDS{$cmd});
			if ($DEBUG && $result) {
				print STDERR "\tGot result: " . $result . "\n";
			}
		}
	}

	# Check the power state, but not too frequently
	if (time() > $lastStatus + $DELAY_STATUS) {
		$lastStatus = time();
		$powerLast  = $power;
		$power      = 0;
		my $result = sendQuery($port, $CMDS{'STATUS'});
		if ($result && $result eq $STATUS_ON) {
			$power = 1;
		}

		# If something has changed, save the state to disk
		if ($powerLast != $power) {
			if ($DEBUG) {
				print STDERR 'New ' . uc($DEV) . ' power state: ' . $power . "\n";
			}
			my ($fh, $tmp) = tempfile($DATA_DIR . uc($DEV) . '.XXXXXXXX', 'UNLINK' => 0);
			print $fh $power . "\n";
			close($fh);
			rename($tmp, $DATA_DIR . uc($DEV));
		}
	}
}

# Cleanup
undef($select);
close($sock);
undef($sock);
$port->close();
undef($port);
exit(0);

sub sendQuery($$) {
	my ($port, $query) = @_;

	# Read until the queue is clear (i.e. no data available)
	# Since we don't have flow control this always causes one read timeout
	$port->lookclear();
	clearBuffer($port);

	# Send the command
	my $bytes = $port->write($query . $CRLF);
	if ($DEBUG) {
		print STDERR "\tWrote (" . $bytes . '): ' . $query . "\n";
	}

	# Wait for a reply (delimited or timeout)
	return collectUntil($port, $DELIMITER);
}

sub clearBuffer($) {
	my ($port) = @_;
	my $byte = 1;
	while (length($byte) > 0) {
		$byte = $port->read(1);
		if ($DEBUG && length($byte)) {
			print STDERR "\tIgnored: " . $byte . "\n";
		}
	}
}

sub collectUntil($$) {
	my ($port, $char) = @_;
	if (length($char) != 1) {
		die('Invalid collection delimiter: ' . $char . "\n");
	}

	# This byte-by-byte reading is not efficient, but it's safe
	# Allow reading forever as long as we don't exceed the silence timeout
	my $count  = 0;
	my $string = '';
	while ($count < $SILENCE_TIMEOUT / $BYTE_TIMEOUT) {
		my $byte = $port->read(1);
		if (length($byte)) {
			$count = 0;
			$string .= $byte;

			if ($DEBUG) {
				print STDERR "\tRead: " . $byte . "\n";
			}

			if ($byte eq $char) {
				last;
			}
		} else {
			$count++;
		}
	}

	# Return undef if there was no data (as opposed to just a delimiter and/or whitespace)
	if (length($string) < 1) {
		if ($DEBUG) {
			print STDERR "Read: <NO DATA>\n";
		}
		return undef();
	}

	# Translate CRLF and CR to LF
	$string =~ s/\r\n/\n/g;
	$string =~ s/\r/\n/g;

	# Strip the trailing delimiter
	$string =~ s/${char}$//;

	# Strip leading or trailing whitespace
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;

	# Return our clean string
	if ($DEBUG) {
		print STDERR 'Read: ' . $string . "\n";
	}
	return $string;
}
