#!/bin/bash

set -ex

mix deps.get
MIX_ENV=test mix deps.compile

if [ "$COVERALLS" == true ]
then
  MIX_ENV=test mix coveralls.test
else
  MIX_ENV=test mix test
fi

