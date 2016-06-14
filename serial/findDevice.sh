#!/bin/bash

# CLI Parameters
USB_LOCATION="${1}"
if [ -z "${USB_LOCATION}" ]; then
	echo "Usage: ${0} USB_LOCATION" 1>&2
	exit 1
fi

# Find the serial adapter
TTY_ID="`ioreg -c IOSerialBSDClient | \
	grep -C 6 "USB-Serial Controller@${USB_LOCATION}" | \
	grep IOSerialBSDClient | \
	cut -d '<' -f 2 | \
	awk '$1 == "class" {print $4}' | \
	cut -d 'x' -f 2 | \
	cut -d ',' -f 1`"
if [ -z "${TTY_ID}" ]; then
	echo "Unable to find TTY_ID for USB_LOCATION: ${USB_LOCATION}" 1>&2
	exit 2
fi

# Find the related device file
DEV="`ioreg -c IOSerialBSDClient | \
	grep -C 12 "${TTY_ID}" | \
	grep 'IODialinDevice' | \
	cut -d '=' -f 2 | \
	awk -F '"' '{print $2}'`"
if [ -z "${DEV}" ]; then
	echo "Unable to find DEV for TTY_ID: ${TTY_ID}" 1>&2
	exit 2
fi

# Display and exit
echo "${DEV}"
exit 0
