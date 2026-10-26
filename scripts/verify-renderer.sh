#!/bin/sh
# Only the packaged browser and synthetic JS; no websites, database or credentials.
set -eu
project_dir=$(cd "$(dirname "$0")/.." && pwd)
runtime_image=${RELEASE_IMAGE:-gym-intel-runtime:local}
docker run --rm --init --network none --read-only \
  --tmpfs /tmp:rw,nosuid,size=64m --memory 512m --cpus 1 --pids-limit 512 \
  --cap-drop ALL --security-opt no-new-privileges \
  -v "$project_dir/test/source_monitor/render_smoke.mjs:/fixture/render_smoke.mjs:ro" \
  "$runtime_image" sh -ec '
    renderer=$(find /app/lib -path "*/priv/source_monitor/render.mjs")
    test -n "$renderer"
    exec node /fixture/render_smoke.mjs "$renderer"
  '
