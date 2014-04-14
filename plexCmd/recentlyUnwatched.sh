#!/bin/bash

NUM_EPISODES=10
MAX_RESULTS=25
HOST="http://beddy.uberzach.com:32400"

URL1="${HOST}/library/sections/2/recentlyViewedShows/"
URL2_POST="allLeaves?unwatched=1"
ELEMENT="Directory"
DIR="TV"
if echo "${1}" | grep -iq Movie; then
	URL1="${HOST}/library/sections/1/recentlyAdded/"
	URL2_POST=""
	ELEMENT="Video"
	DIR="Movies"
fi

SERIES="`curl --silent "${URL1}" | \
	grep "<${ELEMENT} " | \
	head -n "${MAX_RESULTS}" | \
	sed 's%^.*key="/library/metadata/\([0-9]*\).*$%\1%'`"

# Movies need an intermediate step
if [ "${DIR}" == "Movies" ]; then
	IFS=$'\n'
	for i in $SERIES; do
		MOVIE="`curl --silent "${HOST}/library/metadata/${i}/" | \
			grep "<${ELEMENT} " | \
			head -n "${MAX_RESULTS}" | \
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
		head -n "${NUM_EPISODES}" | \
		sed "s%^.*/media/${DIR}/%%"`"

	IFS=$'\n'
	for j in $FILES; do
		echo "${j}"
	done
done
