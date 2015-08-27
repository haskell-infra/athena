#!/usr/bin/env bash

function athena_check_configuration_exists { # params: $1 = machine name
  MACHINE=$1
  TEMPLATE="$ATHENA_SRCDIR/src/machines/_template.nix"
  SRCFILE="$ATHENA_SRCDIR/src/machines/$MACHINE.nix"

  if [ ! -f "$SRCFILE" ]; then
    log_warning "No configuration exists for '$MACHINE'; copying from template first."
    (cp "$TEMPLATE" "$SRCFILE" || exit 1) >/dev/null 2>&1
    perl -pi -e "s/HOSTNAME/$MACHINE/" "$SRCFILE"
    log "Created '$SRCFILE'."
    log "You can run 'athena --create' again to deploy for realsies."
    exit 0;
  fi
}
