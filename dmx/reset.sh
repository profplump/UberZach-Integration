#!/bin/bash

PROCS="rope.pl leds.pl bias.pl fan.pl overhead.pl projectorPower.pl amplifierPower.pl garage.pl rave.pl"

# Find the PID for each named process
PIDS=""
for i in $PROCS; do
	PID="`ps -A -o pid=,command= | grep -v grep | grep ${i} | awk '{print $1}'`"
	PIDS="${PIDS} ${PID}"
done

# Kill everything we found
kill $PIDS
