#!/bin/bash

HOST="http://pms.uberzach.com:32400"
CURL_OPTS=(--silent --connect-timeout 5 --max-time 30)
NUM_SERIES=15
NUM_EPISODES=6
MAX_RESULTS=100

# Select a configuration mode
URL1="${HOST}/library/sections/2/onDeck/"
URL2_POST="children/allLeaves?unwatched=1"
if echo "${1}" | grep -iq Movie; then
	URL1="${HOST}/library/sections/1/recentlyAdded/"
	URL2_POST=""
fi

# Find recent items
ITEMS="`curl ${CURL_OPTS[@]} "${URL1}" | \
	grep '<Video ' | \
	head -n "${MAX_RESULTS}" | \
	sed 's%^.* ratingKey="\([0-9]*\)".*$%\1%'`"

# Resolve the series item
SERIES=""
IFS=$'\n'
for i in $ITEMS; do
	ITEM="`curl ${CURL_OPTS[@]} "${HOST}/library/metadata/${i}/" | \
		grep '<Video ' | \
		head -n "${MAX_RESULTS}"`"
	if echo "${ITEM}" | grep -q 'type="episode"'; then
		KEY="`echo "${ITEM}" | \
			sed 's%^.* parentRatingKey="\([0-9]*\)".*$%\1%'`"
	elif  echo "${ITEM}" | grep -q 'type="movie"'; then
		KEY="`echo "${ITEM}" | \
			grep -v 'lastViewedAt="' | \
			sed 's%^.* ratingKey="\([0-9]*\)".*$%\1%'`"
	else
		echo "Unknown type: ${ITEM}" 1>&2
		exit -1
	fi

	if [ -n "${KEY}" ]; then
		SERIES="${SERIES}${KEY}"$'\n'
	fi
done

SERIES_COUNT=0
IFS=$'\n'
for i in $SERIES; do
	SERIES_COUNT=$(( $SERIES_COUNT + 1 ))
	FILES="`curl ${CURL_OPTS[@]} "${HOST}/library/metadata/${i}/${URL2_POST}" | \
		grep '<Part ' | \
		head -n "${MAX_RESULTS}" | \
		sed 's%^.*file="\([^\"]*\)".*$%\1%' | \
		sed "s%^.*/media/%%"`"

	SEASON_COUNTS=()
	IFS=$'\n'
	for j in $FILES; do
		# Find the season number and increment the count
		# Account no-season items (i.e. movies) separately
		SEASON="`echo "${j}" | sed 's%^.*/Season \([0-9]*\)/.*$%\1%'`"
		if ! echo "${SEASON}" | grep -q '^[0-9]*$'; then
			SEASON=-1
		else
			SEASON_COUNTS[$SEASON]=$(( ${SEASON_COUNTS[$SEASON]} + 1 ))
		fi

		# Limit the number of series (or movies)
		if [ $SERIES_COUNT -gt $NUM_SERIES ]; then
			continue
		# Only output NUM_EPISODES files per season
		elif [ $SEASON -ge 0 ] && [ ${SEASON_COUNTS[$SEASON]} -gt $NUM_EPISODES ]; then
			continue
		fi

		# Print the name, decoding both hex encoding and XML entities
		echo "${j}" | \
			sed 's/%C3%A9/é/' | \
			perl -pe 's/%([0-9a-f]{2})/sprintf("%s", pack("H2",$1))/eig' | \
			perl -e 'use XML::Entities; while (<>) { print XML::Entities::decode('all', $_); }'
	done
done
