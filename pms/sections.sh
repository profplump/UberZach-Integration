#!/bin/bash

curl --silent 'http://localhost:32400/library/sections' | \
	grep '<Directory ' | sed 's%^.* key="\([0-9]*\)".*$%\1%'
