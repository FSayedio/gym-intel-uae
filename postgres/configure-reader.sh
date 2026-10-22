#!/bin/sh
# Compatibility entry point: role setup now covers runtime and migration roles.
set -eu
exec sh /opt/gym-intel/configure-roles.sh
