#!/bin/bash

ROPE="`ps -A -o pid=,command= | grep -v grep | grep rope.pl | awk '{print $1}'`"
LEDS="`ps -A -o pid=,command= | grep -v grep | grep leds.pl | awk '{print $1}'`"
BIAS="`ps -A -o pid=,command= | grep -v grep | grep bias.pl | awk '{print $1}'`"
PROJ="`ps -A -o pid=,command= | grep -v grep | grep projectorPower.pl | awk '{print $1}'`"
FAN="`ps -A -o pid=,command= | grep -v grep | grep fan.pl | awk '{print $1}'`"
AMP="`ps -A -o pid=,command= | grep -v grep | grep ampliferPower.pl | awk '{print $1}'`"
OVERHEAD="`ps -A -o pid=,command= | grep -v grep | grep overhead.pl | awk '{print $1}'`"
GARAGE="`ps -A -o pid=,command= | grep -v grep | grep garage.pl | awk '{print $1}'`"

for i in $ROPE $LEDS $FAN $BIAS $OVERHEAD $GARAGE $AMP $PROJ; do
	if [ -n "${i}" ]; then
		kill $i
	fi
done
