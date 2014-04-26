#!/bin/bash

PROCS="amplifierPower.pl audio.pl bias.pl color.pl debug.pl fan.pl garage.pl leds.pl overhead.pl projectorPower.pl rave.pl rifftrax.pl rope.pl frontApp"

# Find the PID for each named process
PIDS=""
for i in $PROCS; do
	PID="`ps -A -o pid=,command= | grep -v grep | grep ${i} | awk '{print $1}'`"
	PIDS="${PIDS} ${PID}"
done

# Kill everything we found
kill $PIDS

# Always exit cleanly
exit 0
