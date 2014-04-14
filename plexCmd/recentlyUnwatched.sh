#!/bin/bash

NUM_EPISODES=10
HOST="http://beddy.uberzach.com:32400"

SERIES="`curl --silent "${HOST}/library/sections/2/recentlyViewedShows/" | \
	grep '<Directory ' | \
	sed 's%^.*key="/library/metadata/\([0-9]*\)/children".*$%\1%'`"

for i in $SERIES; do
	FILES="`curl --silent "${HOST}/library/metadata/${i}/allLeaves?unwatched=1" | \
		grep '<Part ' | \
		sed 's%^.*file="\([^\"]*\)".*$%\1%' | \
		head -n "${NUM_EPISODES}" | \
		sed 's%^.*/media/%%'`"

	IFS=$'\n'
	for j in $FILES; do
		echo "${j}"
	done
done
