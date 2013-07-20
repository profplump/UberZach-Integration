#!/bin/bash

# Delay if we are currently scanning
WAIT=0
DELAY=5
MAX_WAIT=600
while ~/bin/video/pms/isScanning.sh; do
	sleep $DELAY
	WAIT=$(( $WAIT + $DELAY ))
	if [ $WAIT -ge $MAX_WAIT ]; then
		echo "`basename "${0}"`: Waited ${MAX_WAIT} seconds for scanner. Exiting..." 1>&2
		exit 1
	fi
done

# Optimize
curl --silent --upload-file /dev/null 'http://localhost:32400/library/optimize'
