#!/bin/sh
# Starts the ETL job. Its Python packages live in the etl_deps volume (/deps): they are
# installed on the first start, and again only when requirements.txt changes, so later
# starts need no network.
set -e
if ! cmp -s requirements.txt /deps/requirements.txt; then
  pip install --quiet --no-cache-dir --root-user-action=ignore --upgrade --target /deps -r requirements.txt
  cp requirements.txt /deps/requirements.txt
fi
exec python etl.py "$@"
