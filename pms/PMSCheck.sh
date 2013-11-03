#!/bin/bash

# Config
CURL_TIMEOUT=10
RESTART_DELAY=300
PMS_URL="http://localhost:32400/"
UNWATCHED_SECTION="2"
UNWATCHED_TIMEOUT="${CURL_TIMEOUT}"
UNWATCHED_SLEEP=60
UNWATCHED_RETRIES=5
MIN_UNWATCHED_COUNT=10
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

	# Ensure the media share is mounted
	if [ -z "${FAILED}" ]; then
		if ! ~/bin/video/isMediaMounted; then
			FAILED="Media share not mounted"
		fi
	fi

	# Ask Plex for the top-level status page
	if [ -z "${FAILED}" ]; then
		PAGE="`curl --silent --max-time "${CURL_TIMEOUT}" "${PMS_URL}"`"
		if [ -z "${PAGE}" ]; then
			FAILED="HTTP timeout"
		else
			UPDATE="`echo "${PAGE}" | grep 'updatedAt=' | sed 's%^.*updatedAt="\([0-9]*\)".*$%\1%'`"
			if [ -z "${UPDATE}" ]; then
				FAILED="Invalid update timestamp on status page"
			fi
		fi
	fi

	# Ask Plex for a list of unwatched TV series
	if [ -z "${FAILED}" ]; then
		UNWATCHED_URL="${PMS_URL}library/sections/${UNWATCHED_SECTION}/unwatched"
		TRY=1
		FAILED="Too few unwatched series"
		while [ $TRY -le $UNWATCHED_RETRIES ] && [ -n "${FAILED}" ]; do
			TRY=$(( $TRY + 1 ))
			PAGE="`curl --silent --max-time "${UNWATCHED_TIMEOUT}" "${UNWATCHED_URL}"`"
			COUNT="`echo "${PAGE}" | grep '</Directory>' | wc -l`"
			if [ $COUNT -ge $MIN_UNWATCHED_COUNT ]; then
				FAILED=""
			else
				sleep $UNWATCHED_SLEEP
				FAILED="${FAILED} ${COUNT}"
			fi
		done
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
		~/bin/video/pms/optimize.sh &
	fi

	# Sleep for the next loop or exit
	if [ $LOOP -gt 0 ]; then
		sleep $LOOP
	else
		exit 0
	fi
done
