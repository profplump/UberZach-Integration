#!/bin/bash

# Build URL and cURL opts
source ~/bin/video/pms/curl.sh

# Config
RETRY_DELAY=30
RESTART_DELAY=600
UNWATCHED_SECTION="28"
UNWATCHED_SLEEP=30
UNWATCHED_RETRIES=3
MIN_UNWATCHED_COUNT=5
MAX_MEM=$(( 14 * 1024 * 1024 )) # GB in kB
ADMIN_EMAIL="zach@kotlarek.com"
IFS=''

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
		PAGE="`curl ${CURL_OPTS[@]} "${PMS_URL}/"`"
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
		TRY=1
		FAILED="Too few unwatched series"
		UNWATCHED_URL="${PMS_URL}/library/sections/${UNWATCHED_SECTION}/all?type=2&unwatched=1"
			UNWATCHED_URL+="&X-Plex-Container-Start=0&X-Plex-Container-Size=$(( $MIN_UNWATCHED_COUNT + 2 ))"
		while [ $TRY -le $UNWATCHED_RETRIES ]; do
			PAGE="`curl ${CURL_OPTS[@]} "${UNWATCHED_URL}" 2>&1`"
			COUNT="`echo "${PAGE}" | grep '</Directory>' | wc -l | awk '{print $1}'`"
			if [ $COUNT -ge $MIN_UNWATCHED_COUNT ]; then
				FAILED=""
				break
			fi

			sleep $RETRY_DELAY
			FAILED="${FAILED} ${COUNT}"
			TRY=$(( $TRY + 1 ))
		done
	fi

	# Check Plex's memory usage
	if [ -z "${FAILED}" ]; then
		MEM="`ps awx -o vsize,comm | awk '$0 ~ /\/Plex Media Server$/ {print $1}'`"
		if [ -z "${MEM}" ]; then
			FAILED="Unable to read memory use"
		fi
		if [ $MEM -gt $MAX_MEM ]; then
			FAILED="Memory use too high: ${MEM}/${MAX_MEM} kB"
		fi
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
	fi

	# Sleep for the next loop or exit
	if [ $LOOP -gt 0 ]; then
		sleep $LOOP
	else
		exit 0
	fi
done
