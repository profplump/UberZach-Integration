#!/bin/bash

# Config
CURL_TIMEOUT=2
DATE_TIMEOUT=360
PMS_URL="http://localhost:32400/"

# Command-line config
LOOP=-1
if [ "${1}" ]; then
	LOOP="${1}"
fi

# Run at least once, loop if requested
while [ $LOOP -ne 0 ]; do
	# State tracking
	FAILED=1

	# Ask for the last update time from Plex
	UPDATE="`curl --silent --max-time "${CURL_TIMEOUT}" "${PMS_URL}" | \
		grep 'updatedAt=' | sed 's%^.*updatedAt="\([0-9]*\)".*$%\1%'`"

	# If Plex replied, check the update time
	if [ -n "${UPDATE}" ]; then
		DATE="`date '+%s'`"
		DIFF=$(( $DATE - $UPDATE ));
		if [ $DIFF -le $DATE_TIMEOUT ]; then
			FAILED=0
		fi
	fi

	# If Plex has failed kill it
	if [ $FAILED -gt 0 ]; then
		echo "PMS is non-responsive. Killing..." 1>&2
		killall 'Plex Media Server'
		if [ $LOOP -lt 1 ]; then
			exit 1
		fi
	fi

	# Sleep for the next loop or exit
	if [ $LOOP -gt 0 ]; then
		sleep $LOOP
	else
		exit 0
	fi
done
