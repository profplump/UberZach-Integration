#!/bin/bash

# Config
CURL_TIMEOUT=2
DATE_TIMEOUT=360
PMS_URL="http://localhost:32400/"
ADMIN_EMAIL="zach@kotlarek.com"

# Command-line config
LOOP=-1
if [ "${1}" ]; then
	LOOP="${1}"
fi

# Run at least once, loop if requested
while [ $LOOP -ne 0 ]; do
	# State tracking
	FAILED=""

	# Ask for the last update time from Plex
	UPDATE="`curl --silent --max-time "${CURL_TIMEOUT}" "${PMS_URL}" | \
		grep 'updatedAt=' | sed 's%^.*updatedAt="\([0-9]*\)".*$%\1%'`"

	# If Plex replied, check the update time
	if [ -n "${UPDATE}" ]; then
		DATE="`date '+%s'`"
		DIFF=$(( $DATE - $UPDATE ));
		if [ $DIFF -gt $DATE_TIMEOUT ]; then
			FAILED="Update timeout"
		fi
	else
		FAILED="HTTP timeout"
	fi

	# If Plex has failed kill it
	if [ -n "${FAILED}" ]; then
		ERR_MSG="PMS is non-responsive (${FAILED}). Killing..."
		killall 'Plex Media Server'
		if [ $LOOP -lt 1 ]; then
			echo "${ERR_MSG}" 1>&2
			exit 1
		elif [ -n "${ADMIN_EMAIL}" ]; then
			echo "${ERR_MSG}" | sendmail "${ADMIN_EMAIL}"
		fi
	fi

	# Sleep for the next loop or exit
	if [ $LOOP -gt 0 ]; then
		sleep $LOOP
	else
		exit 0
	fi
done
