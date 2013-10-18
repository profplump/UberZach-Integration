#!/bin/bash

# Defaults
DELAY=5
MAX_WAIT=600

# Accept an alternate MAX_WAIT
if [ -n "${1}" ]; then
	MAX_WAIT="${1}"
fi

# Delay if we are currently scanning
WAIT=0
while ~/bin/video/pms/isScanning.sh; do
	sleep $DELAY
	WAIT=$(( $WAIT + $DELAY ))
	if [ $WAIT -ge $MAX_WAIT ]; then
		echo "`basename "${0}"`: Waited ${MAX_WAIT} seconds for scanner. Exiting..." 1>&2
		exit 1
	fi
done

# Optimize
exec curl --silent --upload-file /dev/null 'http://localhost:32400/library/optimize'
