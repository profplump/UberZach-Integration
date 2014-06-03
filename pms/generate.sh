#!/bin/bash

BASE_URL="http://localhost:32400"

IFS=$'\n'

SECTION="${1}"
if [ -z "${SECTION}" ] || [ $SECTION -lt 1 ] || [ $SECTION -gt 100 ]; then
	echo "Usage: `basename "${0}"` section_number" 1>&2
	exit 1
fi

SERIES="`curl --silent "${BASE_URL}/library/sections/${SECTION}/all" | \
	grep 'key="/library/metadata/[0-9]*/children"' | \
	sed 's%^.*key="\(/library/metadata/[0-9]*/children\)".*$%\1%'`"

for i in $SERIES; do
	SEASONS="`curl --silent "${BASE_URL}${i}" | \
	grep 'key="/library/metadata/[0-9]*/children"' | \
	sed 's%^.*key="\(/library/metadata/[0-9]*/children\)".*$%\1%'`"

	for j in $SEASONS; do
		EPISODES="`curl --silent "${BASE_URL}${j}" | \
		grep '<Video ' | \
		sed 's%^.*ratingKey="\([0-9]*\)".*$%\1%'`"

		for k in $EPISODES; do
			if [ -z "${k}" ] || [ $k -lt 100 ]; then
				echo "Bad episode ID: ${k}" 1>&2
				continue
			fi
			'/Applications/Zach/Media/Plex Media Server.app/Contents/MacOS/Plex Media Scanner' \
				--generate --item "${k}"
		done
	done
done

exit 0
