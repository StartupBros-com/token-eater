#!/usr/bin/env bash
set -euo pipefail

jq -er '
  if type != "array" or any(.[]; type != "array") then
    error("expected paginated release arrays")
  else
    flatten
    | map(select(.draft == false and .prerelease == false))
    | sort_by([.created_at, .id])
    | last
    | .id
  end
'
