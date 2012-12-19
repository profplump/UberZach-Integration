#!/bin/bash

if ps auwx | grep -v grep | grep -q 'Plex Media Scanner'; then
	exit 0
fi
exit 1
