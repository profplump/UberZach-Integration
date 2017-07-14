#!/bin/bash

# Config
RESTART_DELAY=600
UNWATCHED_SECTION="2"
UNWATCHED_SLEEP=30
UNWATCHED_RETRIES=3
MIN_UNWATCHED_COUNT=10
MAX_MEM=$(( 14 * 1024 * 1024 )) # GB in kB
ADMIN_EMAIL="zach@kotlarek.com"
IFS=''
CURL_TIMEOUT=15
CURL_OPTS=(--silent --connect-timeout 5 --max-time $CURL_TIMEOUT)

# Construct URL components from the environment
if [ -z "${PMS_URL}" ]; then
	if [ -z "${PMS_HOST}" ]; then
		PMS_HOST="localhost"
	fi
	if [ -z "${PMS_PORT}" ]; then
		PMS_PORT=32400
	fi
	PMS_URL="https://${PMS_HOST}:${PMS_PORT}"
fi
if [ -z "${PMS_TOKEN}" ]; then
	echo "No PMS_TOKEN provided" 1>&2
fi
CURL_OPTS+=(-H "X-Plex-Token: ${PMS_TOKEN}")

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
	UNWATCHED_TIMEOUT=$(( $CURL_TIMEOUT ))
	if [ -z "${FAILED}" ]; then
		UNWATCHED_URL="${PMS_URL}/library/sections/${UNWATCHED_SECTION}/all?type=2&unwatched=1&sort=titleSort:asc&X-Plex-Container-Start=0&X-Plex-Container-Size=10000"
		TRY=1
		FAILED="Too few unwatched series"
		while [ $TRY -le $UNWATCHED_RETRIES ] && [ -n "${FAILED}" ]; do
			TRY=$(( $TRY + 1 ))
			PAGE="`curl ${CURL_OPTS[@]} --max-time "${UNWATCHED_TIMEOUT}" "${UNWATCHED_URL}" 2>&1`"
			COUNT="`echo "${PAGE}" | grep '</Directory>' | wc -l | awk '{print $1}'`"
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
