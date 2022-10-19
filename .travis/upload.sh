  #!/bin/bash

set -e

# Upload packages to hex
# Only do so when on master

if [[ ! -z "$TRAVIS_TAG" && "$TRAVIS_PULL_REQUEST" == "false" ]]; then
  mix hex.publish --organization simplifi --yes
else
  echo "Skipping upload"
fi
