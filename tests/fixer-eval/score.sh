#!/usr/bin/env bash
# Scores one finished pr-fixer run: score.sh <dest> <log> [--json]. <dest> is the folder prepare.sh
# made, <log> the transcript the person exported. The checks and the log forms are in score.py.
# Exit 0 = every verdict check passed (advisory lines never fail a run), 1 = a verdict check failed,
# 2 = the dest or the log could not be read.
set -u
exec python3 -I "$(cd "$(dirname "$0")" && pwd)/score.py" "$@"
