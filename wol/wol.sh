#!/bin/bash

# We need the target MAC and broadcast addresses
ETHER="${1}"
BCAST="${2}"
if [ -z "${ETHER}" ] || [ -z "${BCAST}" ]; then
	echo "Usage: ${0} MAC broadcast" 1>&2
	exit 1
fi

# UDP needs a port
PORT=7

# Construct the packet
RAW="`echo "${ETHER}" | sed 's/://g'`"
PACKET="FFFFFFFFFFFF"
i=0
while [ $i -lt 16 ]; do
	PACKET="${PACKET}${RAW}"
	i=$(( $i + 1 ))
done

# Send with socat
echo "${PACKET}" | xxd -r -p | socat - "UDP-DATAGRAM:${BCAST}:${PORT},broadcast"
