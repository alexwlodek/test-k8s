#!/usr/bin/env bash
set -euo pipefail

required_tools=(docker kind kubectl helm)
missing_tools=()

for tool in "${required_tools[@]}"; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    missing_tools+=("${tool}")
  fi
done

if ((${#missing_tools[@]} > 0)); then
  printf 'Missing required tools: %s\n' "${missing_tools[*]}" >&2
  printf 'Install the missing tools and run this script again.\n' >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  printf 'Docker is installed but the daemon is not reachable.\n' >&2
  printf 'Start Docker and run this script again.\n' >&2
  exit 1
fi

printf 'All required tools are available.\n'

