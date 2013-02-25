#!/bin/bash

ROPE="`ps -A -o pid=,command= | grep -v grep | grep rope.pl | awk '{print $1}'`"
LEDS="`ps -A -o pid=,command= | grep -v grep | grep leds.pl | awk '{print $1}'`"
FAN="`ps -A -o pid=,command= | grep -v grep | grep fan.pl | awk '{print $1}'`"

for i in $ROPE $LEDS $FAN; do
	if [ -n "${i}" ]; then
		kill $i
	fi
done
