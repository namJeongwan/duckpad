#!/bin/sh
set -eu
python3 -B -m unittest -v tests.governance.test_review_gate
