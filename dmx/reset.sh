#!/bin/bash

ROPE="`ps -A -o pid=,command= | grep -v grep | grep rope.pl | awk '{print $1}'`"
if [ -n "${ROPE}" ]; then
	kill $ROPE
fi
