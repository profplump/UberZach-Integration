#!/bin/bash

# Config
CURL_TIMEOUT=2
RESTART_DELAY=120
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

	# If Plex replied, assume thing are workingcheck the update time
	if [ -z "${UPDATE}" ]; then
		FAILED="HTTP timeout"
	fi

	# If Plex has failed kill it
	if [ -n "${FAILED}" ]; then
		ERR_MSG="PMS is non-responsive (${FAILED}). Killing..."
		echo "${ERR_MSG}" 1>&2

		~/bin/video/pms/killPMS.sh
		if [ $LOOP -lt 1 ]; then
			exit 1
		elif [ -n "${ADMIN_EMAIL}" ]; then
			echo -e "Subject: PMS Restart\n\n${ERR_MSG}" | sendmail "${ADMIN_EMAIL}"
		fi

		# Give plex a breather to get restarted before we check again
		sleep "${RESTART_DELAY}"

		# Re-index (in the background)
		~/bin/video/isScanning && \
			curl --silent --upload-file /dev/null "${PMS_URL}library/optimize" &
	fi

	# Sleep for the next loop or exit
	if [ $LOOP -gt 0 ]; then
		sleep $LOOP
	else
		exit 0
	fi
done
