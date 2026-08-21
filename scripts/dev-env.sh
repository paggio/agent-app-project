#!/usr/bin/env bash
# Load stack/dev.env into the environment. SOURCED, never executed.
#
#   . "$ROOT/scripts/dev-env.sh"
#
# Exists so that the variables a smoke suite needs are part of the ship process rather
# than a precondition a human has to remember. smoke.py dies on an undefined ${VAR} by
# design — guessing a signup code would report "registration is closed" as though the
# backend were broken — so something has to supply them, and that something should not be
# a paragraph in a README.
#
# Two rules:
#   1. The real environment wins. Only unset variables are filled in, so an explicit
#      `SIGNUP_CODE=x ./scripts/iterate.sh ...` and a genuinely deployed environment both
#      override the file.
#   2. Exported, so `docker compose` interpolation and smoke.py both see them as children.
#   3. Every name it filled in is recorded in DEV_ENV_DEFAULTED, because "this value is a
#      committed local placeholder" is what lets verify.sh refuse a remote pass rather than
#      register a smoke account against a real environment with a public signup code.
#
# DEV_ENV_FILE points it somewhere else; a missing file is not an error, because a change
# that needs no variables should not have to invent one.

_dev_env_file="${DEV_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stack/dev.env}"

if [ -f "$_dev_env_file" ]; then
  while IFS= read -r _dev_env_line || [ -n "$_dev_env_line" ]; do
    case "$_dev_env_line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    _dev_env_key="${_dev_env_line%%=*}"
    _dev_env_val="${_dev_env_line#*=}"
    # `${!k+x}` is indirect expansion with the +x test: empty when unset, "x" when set to
    # anything including the empty string. An explicitly empty SIGNUP_CODE therefore stays
    # empty, which is how a deployment asks for registration to be closed.
    if [ -z "${!_dev_env_key+x}" ]; then
      export "$_dev_env_key=$_dev_env_val"
      DEV_ENV_DEFAULTED="${DEV_ENV_DEFAULTED:+$DEV_ENV_DEFAULTED }$_dev_env_key"
    fi
  done < "$_dev_env_file"
fi

export DEV_ENV_DEFAULTED="${DEV_ENV_DEFAULTED:-}"

unset _dev_env_file _dev_env_line _dev_env_key _dev_env_val
