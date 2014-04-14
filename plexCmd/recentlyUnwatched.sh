#!/bin/bash

NUM_EPISODES=10
HOST="http://beddy.uberzach.com:32400"

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

IFS=$'\n'
for i in $SERIES; do
	FILES="`curl --silent "${HOST}/library/metadata/${i}/${URL2_POST}" | \
		grep '<Part ' | \
		sed 's%^.*file="\([^\"]*\)".*$%\1%' | \
		sed "s%^.*/media/%%"`"

	scounts=()
	IFS=$'\n'
	for j in $FILES; do
		# Find the season number, or assume 0 if none is available
		season="`echo "${j}" | sed 's%^.*/Season \([0-9]*\)/.*$%\1%'`"
		if ! echo "${season}" | grep -q '^[0-9]*$'; then
			season=0
		fi

		# Only output NUM_EPISODES files per season
		# This allows discontinous output, but that's desirable compared to only getting season 0
		scounts[$season]=$(( ${scounts[$season]} + 1 ))
		if [ ${scounts[$season]} -gt $NUM_EPISODES ]; then
			continue
		fi

		# If we're still around, this is a show we want
		echo "${j}"
	done
done
