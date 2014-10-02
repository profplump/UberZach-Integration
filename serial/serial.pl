#!/usr/bin/perl
use strict;
use warnings;
use File::Basename;
use File::Temp qw( tempfile );
use IO::Select;
use IO::Socket::UNIX;
use Device::SerialPort;
use Time::HiRes qw( usleep sleep time );
use IPC::System::Simple qw( system capture );

# Local modules
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use lib dirname(abs_path($0));
use DMX;

# Prototypes
sub sendQuery($$);
sub clearBuffer($);
sub collectUntil($$);

# Device parameters
my ($DEV, $PORT, $BLUETOOTH, $CRLF, $DELIMITER, %CMDS, %STATUS_CMDS);
if (basename($0) =~ /PROJECTOR/i) {
	$DEV       = 'Projector';
	$PORT      = '/dev/tty.usbserial-A5006xbj';
	$BLUETOOTH = 0;
	$CRLF      = "\r\n";
	$DELIMITER = ':';
	%CMDS      = (
		'INIT'            => '',
		'ON'              => 'PWR ON',
		'OFF'             => 'PWR OFF',
		'STATUS'          => 'PWR?',
		'DYNAMIC'         => 'CMODE 06',
		'LIVING_ROOM'     => 'CMODE 0C',
		'NATURAL'         => 'CMODE 07',
		'THEATER'         => 'CMODE 05',
		'THEATER_BLACK_1' => 'CMODE 09',
		'THEATER_BLACK_2' => 'CMODE 0A',
		'XV'              => 'CMODE 0B',
		'COLOR'           => 'CMODE?',
		'HDMI_1'          => 'SOURCE 30',
		'HDMI_2'          => 'SOURCE A0',
		'VGA'             => 'SOURCE 20',
		'INPUT'           => 'SOURCE?',
		'LAMP'            => 'LAMP?',
	);
	%STATUS_CMDS = (
		'STATUS' => { 'MATCH'   => [ qr/^PWR=/,                 qr/PWR=01/ ] },
		'COLOR'  => { 'EVAL'    => [ qr/^CMODE=[0-9A-Z]{2}$/i,  'if ($a =~ /06$/i) { $a = "DYNAMIC" } elsif ($a =~ /0C$/i) { $a = "LIVING_ROOM" } elsif ($a =~ /07$/i) { $a = "NATURAL" } elsif ($a =~ /05$/i) { $a = "THEATER" } elsif ($a =~ /09$/i) { $a = "THEATER_BLACK_1" } elsif ($a =~ /0A$/i) { $a = "THEATER_BLACK_2" } elsif ($a =~ /0B$/i) { $a = "XV" }' ] },
		'INPUT'  => { 'EVAL'    => [ qr/^SOURCE=[0-9A-Z]{2}$/i, 'if ($a =~ /30$/i) { $a = "HDMI_1" } elsif ($a =~ /A0$/i) { $a = "HDMI_2" } elsif ($a =~ /20$/i) { $a = "VGA" }' ] },
		'LAMP'   => { 'REPLACE' => qr/^LAMP=(\d+)$/i },
	);
} elsif (basename($0) =~ /AMPLIFIER/i) {
	$DEV       = 'Amplifier';
	$PORT      = '/dev/tty.usbserial-AM01C96Q';
	$BLUETOOTH = 0;
	$CRLF      = "\r";
	$DELIMITER = "\r";
	%CMDS      = (
		'INIT'         => '',
		'ON'           => 'PWON',
		'OFF'          => 'PWSTANDBY',
		'STATUS'       => 'PW?',
		'VOL'          => 'MV?',
		'VOL+'         => 'MVUP',
		'VOL-'         => 'MVDOWN',
		'MUTE'         => 'MUON',
		'UNMUTE'       => 'MUOFF',
		'INPUT'        => 'SI?',
		'TV'           => 'SITV',
		'DVD'          => 'SIDVD',
		'MODE'         => 'MS?',
		'SURROUND'     => 'MSDOLBY DIGITAL',
		'STEREO'       => 'MS7CH STEREO',
		'TV'           => 'SITV',
		'INPUT'        => 'SI?',
		'INPUT_MODE'   => 'SD?',
		'INPUT_AUTO'   => 'SDAUTO',
		'INPUT_ANALOG' => 'SDANALOG',
		'INPUT_EXT'    => 'SDEXT.IN-1',

	);
	%STATUS_CMDS = (
		'STATUS' => { 'MATCH'   => [ qr/^PW/, qr/$CMDS{'ON'}/ ] },
		'MODE'   => { 'EVAL'    => [ qr/^MS/, 'if ($a =~ /STEREO/i) { $a = "STEREO" } elsif ($a =~ /MS(?:DOLBY|DTS)/i) { $a = "SURROUND" }' ] },
		'VOL'    => { 'EVAL'    => [ qr/^MV/, '$a =~ s/^MV//; if (length($a) > 2) { $a =~ s/(\d\d)(\d)/$1.$2/ }' ] },
		'INPUT'  => { 'REPLACE' => qr/^SI(.*)/ },
	);
} elsif (basename($0) =~ /TV/i) {
	$DEV       = 'TV';
	$PORT      = '/dev/tty.usbserial-A501JRBK';
	$BLUETOOTH = 0;
	$CRLF      = "\r";
	$DELIMITER = "\r";
	%CMDS      = (
		'INIT'      => 'RSPW1   ',
		'ON'        => 'POWR1   ',
		'OFF'       => 'POWR0   ',
		'STATUS'    => 'POWR?   ',
		'MUTE'      => 'MUTE1   ',
		'UNMUTE'    => 'MUTE2   ',
		'INPUT'     => 'IAVD?   ',
		'TV'        => 'ITVD0   ',
		'PLEX'      => 'IAVD7   ',
		'VOL'       => 'VOLM?   ',
		'CH+'       => 'CHUP1   ',
		'CH-'       => 'CHDW1   ',
		'CC'        => 'CLCP1   ',
		'VOL0'      => 'VOLM0   ',
		'VOL1'      => 'VOLM1   ',
		'VOL2'      => 'VOLM2   ',
		'VOL3'      => 'VOLM3   ',
		'VOL4'      => 'VOLM4   ',
		'VOL5'      => 'VOLM5   ',
		'VOL6'      => 'VOLM6   ',
		'VOL7'      => 'VOLM7   ',
		'VOL8'      => 'VOLM8   ',
		'VOL9'      => 'VOLM9   ',
		'VOL10'     => 'VOLM10  ',
		'VOL11'     => 'VOLM11  ',
		'VOL12'     => 'VOLM12  ',
		'VOL13'     => 'VOLM13  ',
		'VOL14'     => 'VOLM14  ',
		'VOL15'     => 'VOLM15  ',
		'VOL16'     => 'VOLM16  ',
		'VOL17'     => 'VOLM17  ',
		'VOL18'     => 'VOLM18  ',
		'VOL19'     => 'VOLM19  ',
		'VOL20'     => 'VOLM20  ',
		'VOL21'     => 'VOLM21  ',
		'VOL22'     => 'VOLM22  ',
		'VOL23'     => 'VOLM23  ',
		'VOL24'     => 'VOLM24  ',
		'VOL25'     => 'VOLM25  ',
		'VOL26'     => 'VOLM26  ',
		'VOL27'     => 'VOLM27  ',
		'VOL28'     => 'VOLM28  ',
		'VOL29'     => 'VOLM29  ',
		'VOL30'     => 'VOLM30  ',
		'VOL31'     => 'VOLM31  ',
		'VOL32'     => 'VOLM32  ',
		'VOL33'     => 'VOLM33  ',
		'VOL34'     => 'VOLM34  ',
		'VOL35'     => 'VOLM35  ',
		'VOL36'     => 'VOLM36  ',
		'VOL37'     => 'VOLM37  ',
		'VOL38'     => 'VOLM38  ',
		'VOL39'     => 'VOLM39  ',
		'VOL40'     => 'VOLM40  ',
		'VOL41'     => 'VOLM41  ',
		'VOL42'     => 'VOLM42  ',
		'VOL43'     => 'VOLM43  ',
		'VOL44'     => 'VOLM44  ',
		'VOL45'     => 'VOLM45  ',
		'VOL46'     => 'VOLM46  ',
		'VOL47'     => 'VOLM47  ',
		'VOL48'     => 'VOLM48  ',
		'VOL49'     => 'VOLM49  ',
		'VOL50'     => 'VOLM50  ',
		'VOL51'     => 'VOLM51  ',
		'VOL52'     => 'VOLM52  ',
		'VOL53'     => 'VOLM53  ',
		'VOL54'     => 'VOLM54  ',
		'VOL55'     => 'VOLM55  ',
		'VOL56'     => 'VOLM56  ',
		'VOL57'     => 'VOLM57  ',
		'VOL58'     => 'VOLM58  ',
		'VOL59'     => 'VOLM59  ',
		'VOL60'     => 'VOLM60  ',
	);
	%STATUS_CMDS = (
		'STATUS' => { 'MATCH' => [ qr/\d/, qr/1/ ] },
		'VOL'    => { 'EVAL'  => [ qr/\d/, '' ] },
		'INPUT'  => { 'EVAL'  => [ qr/(\d|ERR)/, 'if ($a =~ /7/i) { $a = "PLEX" } elsif ($a =~ /\d/i) { $a = "OTHER" } else { $a = "TV" }' ] },
	);
} else {
	die("No device specified\n");
}

# App config
my $DATA_DIR        = DMX::dataDir();
my $CMD_FILE        = uc($DEV);
my $BT_CHECK        = $ENV{'HOME'} . '/bin/btcheck';
my $BYTE_TIMEOUT    = 50;
my $SILENCE_TIMEOUT = $BYTE_TIMEOUT * 10;

# Debug
my $DEBUG = 0;
if ($ENV{'DEBUG'}) {
	$DEBUG = $ENV{'DEBUG'};
	print STDERR "Debug enabled\n";
}

# Command-line arguments
my ($DELAY) = @ARGV;
if (!$DELAY) {
	$DELAY = 1;
}

# Sanity check
if (!-r $PORT) {
	die('Serial port not available: ' . $PORT . "\n");
} elsif (!-d $DATA_DIR) {
	die('Data directory not available: ' . $DATA_DIR . "\n");
}

# Wait for the serial port to become available
if ($BLUETOOTH) {
	system($BT_CHECK, $DEV);
	if ($? != 0) {
		sleep($DELAY);
		die('Bluetooth device "' . $DEV . "\" not available\n");
	}
}

# Socket init
my $select = DMX::selectSock($CMD_FILE);

# Port init
my $port = new Device::SerialPort($PORT)
  or die('Unable to open serial connection: ' . $PORT . ": ${!}\n");
$port->read_const_time($BYTE_TIMEOUT);

# Init (clear any previous state)
sendQuery($port, $CMDS{'INIT'});

# State
my $lastStatus = 0;
my %STATUS     = ();
foreach my $cmd (keys(%STATUS_CMDS)) {
	my %tmp = ('status' => 0, 'last' => '');
	$tmp{'path'} = $DATA_DIR . uc($DEV);
	if ($cmd ne 'STATUS') {
		$tmp{'path'} .= '_' . uc($cmd);
	}
	if (-r $tmp{'path'}) {
		unlink($tmp{'path'});
	}

	$STATUS{$cmd} = \%tmp;
}

# Loop forever
while (1) {

	# Calculate our next timeout
	# Hold on select() but not more than $DELAY after our last update
	my $timeout = ($lastStatus + $DELAY) - time();
	if ($timeout < 0) {
		$timeout = 0;
	}
	if ($DEBUG > 1) {
		print STDERR 'Waiting for commands with timeout: ' . $timeout . "\n";
	}

	# Check for queued commands
	my @ready_clients = $select->can_read($timeout);
	foreach my $fh (@ready_clients) {

		# Ensure we won't block on recv()
		$fh->blocking(0);

		# Grab the inbound text
		while (defined($fh->recv(my $text, DMX::maxCmdLen()))) {

			# Clean the input data
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

			# Send commands to serial device
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
	}

	# Read periodic data, but not too frequently
	if (time() > $lastStatus + $DELAY) {

		# Record the last status update time
		$lastStatus = time();

		foreach my $cmd (keys(%STATUS_CMDS)) {

			# Save the previous status
			$STATUS{$cmd}->{'last'} = $STATUS{$cmd}->{'status'};

			# Less typing
			my $scmd = $STATUS_CMDS{$cmd};

			# Query
			if (!defined($CMDS{$cmd})) {
				die('No such command: ' . $cmd . "\n");
			}
			my $result = sendQuery($port, $CMDS{$cmd});

			# On read error wait a short while for the device to recover
			if (!defined($result) || $result eq '' || ! ($result =~ /[[:print:]]/)) {
				print STDERR 'Read error. Delaying ' . ( 4 * $DELAY ) . " seconds\n";
				sleep(4 * $DELAY);
				next;
			}

			# Process the (non-empty) result as requested
			if ($scmd->{'MATCH'}) {
				if ($result =~ $scmd->{'MATCH'}[0]) {
					if ($result =~ $scmd->{'MATCH'}[1]) {
						$STATUS{$cmd}->{'status'} = 1;
					} else {
						$STATUS{$cmd}->{'status'} = 0;
					}
				}
			} elsif ($scmd->{'REPLACE'}) {
				if ($result =~ $scmd->{'REPLACE'}) {
					$STATUS{$cmd}->{'status'} = $result;
					$STATUS{$cmd}->{'status'} =~ s/$scmd->{'REPLACE'}/$1/;
				}
			} elsif ($scmd->{'EVAL'}) {
				my $a = $result;
				if ($result =~ $scmd->{'EVAL'}[0]) {
					eval($scmd->{'EVAL'}[1]);
					$STATUS{$cmd}->{'status'} = $a;
				}
			} else {
				die('Invalid status match type "' . (keys(%{$scmd}))[0] . '" in command: ' . $cmd . "\n");
			}

			# Ensure the data is clean
			$STATUS{$cmd}->{'status'} =~ s/[^\w\.\-]/_/g;

			# If something has changed, save the state to disk
			# (if the output file does not exist, something has changed)
			if ($STATUS{$cmd}->{'status'} ne $STATUS{$cmd}->{'last'} || !-r $STATUS{$cmd}->{'path'}) {
				if ($DEBUG) {
					print STDERR 'New ' . uc($DEV) . ' status: ' . $cmd . ' => ' . $STATUS{$cmd}->{'status'} . "\n";
				}
				my ($fh, $tmp) = tempfile($STATUS{$cmd}->{'path'} . '.XXXXXXXX', 'UNLINK' => 0);
				print $fh $STATUS{$cmd}->{'status'} . "\n";
				close($fh);
				rename($tmp, $STATUS{$cmd}->{'path'});
			}
		}
	}
}

# Cleanup
undef($select);
$port->close();
undef($port);
exit(0);

sub sendQuery($$) {
	my ($port, $query) = @_;

	# Enforce an inter-command delay
	usleep($SILENCE_TIMEOUT);

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

			if ($DEBUG > 1) {
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
