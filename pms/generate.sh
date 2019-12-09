#!/bin/bash

# Build URL and cURL opts
source ~/bin/video/pms/curl.sh

SECTION="${1}"
if [ -z "${SECTION}" ] || [ $SECTION -lt 1 ] || [ $SECTION -gt 100 ]; then
	echo "Usage: `basename "${0}"` section_number" 1>&2
	exit 1
fi

SERIES="`curl ${CURL_OPTS[@]} "${PMS_URL}/library/sections/${SECTION}/all" | \
	grep 'key="/library/metadata/[0-9]*/children"' | \
	sed 's%^.*key="\(/library/metadata/[0-9]*/children\)".*$%\1%'`"

IFS=$'\n'
for i in $SERIES; do
	SEASONS="`curl ${CURL_OPTS[@]} "${PMS_URL}${i}" | \
	grep 'key="/library/metadata/[0-9]*/children"' | \
	sed 's%^.*key="\(/library/metadata/[0-9]*/children\)".*$%\1%'`"

	IFS=$'\n'
	for j in $SEASONS; do
		IFS=''
		EPISODES="`curl ${CURL_OPTS[@]} "${PMS_URL}${j}" | \
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
