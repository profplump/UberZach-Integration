#!/bin/bash

# Config
CURL_TIMEOUT=2
DATE_TIMEOUT=1800
RESTART_DELAY=60
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
		echo "${ERR_MSG}" 1>&2

		killall 'Plex Media Server'
		if [ $LOOP -lt 1 ]; then
			exit 1
		elif [ -n "${ADMIN_EMAIL}" ]; then
			echo -e "Subject: PMS Restart\n\n${ERR_MSG}" | sendmail "${ADMIN_EMAIL}"
		fi

		# Give plex a breather to get restarted before we check again
		# (I would love to re-optimize here too, but that's tricky to time efficiently)
		sleep "${RESTART_DELAY}"
	fi

	# Sleep for the next loop or exit
	if [ $LOOP -gt 0 ]; then
		sleep $LOOP
	else
		exit 0
	fi
done
