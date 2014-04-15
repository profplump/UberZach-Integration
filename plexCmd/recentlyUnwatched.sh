#!/bin/bash

HOST="http://beddy.uberzach.com:32400"
NUM_SERIES=10
NUM_EPISODES=5

# Select a configuration mode
URL1="${HOST}/library/sections/2/recentlyViewedShows/"
URL2_POST="allLeaves?unwatched=1"
ELEMENT="Directory"
MOVIES=0
if echo "${1}" | grep -iq Movie; then
	MOVIES=1
	URL1="${HOST}/library/sections/1/recentlyAdded/"
	URL2_POST=""
	ELEMENT="Video"
fi

SERIES="`curl --silent "${URL1}" | \
	grep "<${ELEMENT} " | \
	sed 's%^.*key="/library/metadata/\([0-9]*\).*$%\1%'`"

# Movies need an intermediate step
if [ "${MOVIES}" -gt 0 ]; then
	IFS=$'\n'
	for i in $SERIES; do
		MOVIE="`curl --silent "${HOST}/library/metadata/${i}/" | \
			grep "<${ELEMENT} " | \
			grep -v 'lastViewedAt="' | \
			sed 's%^.*key="/library/metadata/\([0-9]*\).*$%\1%'`"

		if [ -n "${MOVIE}" ]; then
			UNWATCHED="${UNWATCHED}${MOVIE}"$'\n'
		fi
	done
	SERIES="${UNWATCHED}"
fi

SERIES_COUNT=0
IFS=$'\n'
for i in $SERIES; do
	SERIES_COUNT=$(( $SERIES_COUNT + 1 ))
	FILES="`curl --silent "${HOST}/library/metadata/${i}/${URL2_POST}" | \
		grep '<Part ' | \
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
		if [ $SEASON -lt 0 ]; then
			if [ $SERIES_COUNT -gt $NUM_SERIES ]; then
				continue
			fi
		# Only output NUM_EPISODES files per season
		# This allows discontinous output, but that's desirable compared to only getting season 0
		elif [ ${SEASON_COUNTS[$SEASON]} -gt $NUM_EPISODES ]; then
			continue
		fi

		# If we're still around, this is an item we want
		echo "${j}" | perl -pe 's/%([0-9a-f]{2})/sprintf("%s", pack("H2",$1))/eig'
	done
done
