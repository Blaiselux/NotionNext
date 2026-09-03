#!/usr/bin/env bash
set -Eeuo pipefail

readonly requested_command="${SSH_ORIGINAL_COMMAND:-}"

if [[ "$requested_command" =~ ^deploy\ (sha-[0-9a-f]{40})\ ([A-Za-z0-9][A-Za-z0-9-]{0,38})$ ]]; then
  exec sudo /usr/local/sbin/notionnext-deploy \
    "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
fi

printf 'This SSH key may only deploy a validated NotionNext commit.\n' >&2
exit 64
