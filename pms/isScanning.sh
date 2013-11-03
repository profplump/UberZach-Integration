#!/bin/bash

# Return true if scanning
if ps auwx | grep -v grep | grep -q 'Plex Media Scanner'; then
	exit 0
fi

# Return true if optimizing
if ps auwx | grep -v grep | grep curl | grep -q 'upload-file'; then
	exit 0
fi

# Otherwise return false
exit 1
