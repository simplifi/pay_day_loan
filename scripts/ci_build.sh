#!/bin/bash

set -ex

mix compile --warnings-as-errors
MIX_ENV=test mix compile

if [ "$COVERALLS" == true ]
then
  MIX_ENV=test mix coveralls.travis
else
  MIX_ENV=test mix test
fi

if [ "$DIALYZER" == true ]
then
  mix dialyzer
fi
