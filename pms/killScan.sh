#!/bin/bash

# Find all scanner processes
PROCS="`ps -A -o "pid,lstart,command" | grep -v grep | grep 'Plex Media Scanner'`"
if [ -z "${PROCS}" ]; then
	exit
fi

IFS=''
echo "${PROCS}" | \
while read -r PROC; do
	# Parse the line
	PID="`echo "${PROC}" | awk '{print $1}'`"
	DATE="`echo "${PROC}" | awk '{print $2, $3, $4, $5, $6}'`"
	TS="`date -j -f '%a %b %d %T %Y' "${DATE}" '+%s' 2>/dev/null`"
	NOW="`date '+%s'`"

	# Deal with parsing errors
	if [ -z "${TS}" ]; then
		echo "Invalid date: ${DATE}" 1>&2
		echo "Full line: ${PROC}" 1>&2
		continue
	fi

	# Kill scanners more than 30 minutes old
	AGE=$(( $NOW - $TS ))
	if [ $AGE -gt 1800 ]; then
		echo "Killing ${PROC}"
		kill -9 "${PID}"
	fi
done
