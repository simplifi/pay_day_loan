#!/bin/bash

set -e

# Upload packages to hex
# Only do so when a new version is tagged

if [[ ! -z "$TRAVIS_TAG" && "$TRAVIS_PULL_REQUEST" == "false" ]]; then
  mix hex.publish --yes
else
  echo "Skipping upload"
fi
