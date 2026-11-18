#!/bin/bash

# Enforce shell discipline
set -euox pipefail

SOURCE="${BASH_SOURCE[0]}"
DIR=`dirname $SOURCE`
TEST_TEMPLATE_DIR="test"

for filename in $DIR/ci/*.yaml; do
  echo "Dry run with '$filename'"
  helm template . -f $filename --output-dir ${TEST_TEMPLATE_DIR}
  rm -f "${TEST_TEMPLATE_DIR}/${PWD##*/}/templates/kong.yaml"
  kubectl apply --dry-run=client --recursive --filename ${TEST_TEMPLATE_DIR}/
  rm -rf ${TEST_TEMPLATE_DIR}
  echo `printf "%0.s*" {1..30}`
done
