#!/bin/bash

# Config
CURL_TIMEOUT=15
RESTART_DELAY=600
UNWATCHED_SECTION="2"
UNWATCHED_SLEEP=60
UNWATCHED_RETRIES=5
MIN_UNWATCHED_COUNT=10
MAX_VSIZE=$(( 10 * 1024 * 1024 )) # 10 GB in kB
ADMIN_EMAIL="zach@kotlarek.com"

# Construct a URL from the envrionment
if [ -z "${PMS_URL}" ]; then
	PMS_URL="http://127.0.0.1:32400/"
fi
PMS_AUTH=""
if [ -n "${PMS_TOKEN}" ]; then
	PMS_AUTH="X-Plex-Token=${PMS_TOKEN}"
fi

# Heady allows 0 unwatched
if hostname | grep -qi heady; then
	MIN_UNWATCHED_COUNT=0
fi

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
		PAGE="`curl --silent --max-time "${CURL_TIMEOUT}" "${PMS_URL}?${PMS_AUTH}"`"
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
	UNWATCHED_TIMEOUT=$(( $CURL_TIMEOUT ))
	if [ -z "${FAILED}" ]; then
		UNWATCHED_URL="${PMS_URL}library/sections/${UNWATCHED_SECTION}/all?${PMS_AUTH}&type=2&unwatched=1&sort=titleSort:asc&X-Plex-Container-Start=0&X-Plex-Container-Size=10000"
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
				UNWATCHED_TIMEOUT=$(( $UNWATCHED_TIMEOUT + $CURL_TIMEOUT ))
			fi
		done
	fi

	# Check Plex's memory usage
	if [ -z "${FAILED}" ]; then
		VSIZE="`ps awx -o vsize,comm | awk '$0 ~ /\/Plex Media Server$/ {print $1}'`"
		if [ -z "${VSIZE}" ]; then
			FAILED="Unable to read memory use"
		fi
		if [ $VSIZE -gt $MAX_VSIZE ]; then
			FAILED="Memory use too high: ${VSIZE}/${MAX_VSIZE} kB"
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

		# Re-index (in the background)
		~/bin/video/pms/optimize.sh &

	# If Plex was super slow, optimize it
	elif [ $UNWATCHED_TIMEOUT -gt $(( $CURL_TIMEOUT * $(( $UNWATCHED_RETRIES / 2 )) )) ]; then
		ERR_MSG="PMS is slow (${UNWATCHED_TIMEOUT}). Optimizing..."
		echo "${ERR_MSG}" 1>&2

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
