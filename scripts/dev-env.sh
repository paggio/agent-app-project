#!/usr/bin/env bash
# Fill in the variables the joined stack and the suites need. SOURCED, never executed.
#
#   . "$ROOT/scripts/dev-env.sh"
#
# Exists so that the variables a smoke suite needs are part of the ship process rather
# than a precondition a human has to remember. smoke.py dies on an undefined ${VAR} by
# design — guessing a signup code would report "registration is closed" as though the
# backend were broken — so something has to supply them, and that something should not be
# a paragraph in a README.
#
# THREE LAYERS, highest precedence first. docs/adr/0006 is the decision.
#
#   1. the real environment          `CHAT_MODEL=echo ./scripts/iterate.sh …`, or a
#                                    genuinely deployed environment. Always wins.
#   2. stack/dev.env                 this repo's committed view of the joined stack.
#   3. chatbot-backend/.env          the backend developer's own gitignored file, for the
#                                    non-secret names in SUBMODULE_ENV_ALLOW below.
#
# Rules that hold across all of them:
#   * Only UNSET variables are filled in. `${!k+x}` is indirect expansion with the +x
#     test: empty when unset, "x" when set to anything including the empty string. An
#     explicitly empty SIGNUP_CODE therefore stays empty, which is how a deployment asks
#     for registration to be closed.
#   * Exported, so `docker compose` interpolation and smoke.py both see them as children.
#   * Every name filled in is recorded, because "where did this value come from" decides
#     whether verify.sh may run a remote pass. The two records mean different things and
#     are deliberately not one list:
#       DEV_ENV_DEFAULTED        came from a COMMITTED placeholder. verify.sh refuses a
#                                remote pass for SIGNUP_CODE/SMOKE_PASSWORD on this basis.
#       SUBMODULE_ENV_DEFAULTED  came from a gitignored .env. A real local value, so it
#                                must NOT trigger that refusal.
#
# DEV_ENV_FILE points layer 2 somewhere else; a missing file at either layer is not an
# error, because a change that needs no variables should not have to invent one, and CI
# has no .env at all.
#
# NOT A SHELL. The parser handles `KEY=VALUE`, `#` comments, blank lines and an optional
# `export ` prefix. It does not strip quotes, expand `$VAR`, or honour line continuations.
# Layer 3's file belongs to another repo and we do not get to define a grammar for it.

_dev_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Layer 3 is restricted to an ALLOWLIST, and it holds only names that (a) the joined stack
# actually interpolates and (b) are not secrets. This is a fail-closed choice: a denylist
# of secret-looking names fails open the first time a credential is called something
# unexpected, and this repo writes run artifacts — verify.json, smoke.json, container
# logs, repair prompts — so a credential in ITS environment is one careless dump from
# being committed. AWS credentials are deliberately absent and must stay absent: they
# already reach the container over compose's `env_file`, read by the Docker daemon and
# never by a process here. See docs/adr/0006.
SUBMODULE_ENV_ALLOW="CHAT_MODEL BEDROCK_MODEL_ID BEDROCK_MAX_TOKENS"

# The joined stack's own credentials file carries the MODE those credentials are for,
# and this allowlist is what lets exactly that through and nothing else. Same mechanism,
# same fail-closed argument as the line above: a name not listed here never reaches a
# process in this repo, and AWS_* is deliberately absent and must stay absent — the
# credentials reach the containers over compose's env_file, read by the Docker daemon.
#
# WHY THE MODE HAS TO COME THROUGH HERE rather than through env_file like the
# credentials do: `environment:` beats `env_file:` in compose, and
# chatbot-backend/docker-compose.yml declares `CHAT_MODEL: ${CHAT_MODEL:-echo}` under
# `environment:`. So CHAT_MODEL in the credentials file is silently ignored unless it is
# ALSO in the process environment for compose to interpolate. Measured, not assumed.
# docs/adr/0017.
SECRETS_ENV_ALLOW="CHAT_MODEL EVAL_JUDGE"

# $1 file · $2 name of the variable that accumulates the names filled in · $3 allowlist,
# space-separated; empty means every name in the file is eligible.
_dev_env_layer() {
  local _f="$1" _record="$2" _allow="${3-}" _line _key _val
  [ -f "$_f" ] || return 0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%$'\r'}"
    _line="${_line#"${_line%%[![:space:]]*}"}"
    case "$_line" in
      ''|'#'*) continue ;;
      export[[:space:]]*)
        _line="${_line#export}"
        _line="${_line#"${_line%%[![:space:]]*}"}" ;;
    esac
    case "$_line" in *=*) ;; *) continue ;; esac
    _key="${_line%%=*}"
    _val="${_line#*=}"
    # A key with anything but [A-Za-z0-9_] in it is not an assignment we understand, and
    # `export` would fail on it. Skip rather than die: the file is not ours.
    case "$_key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    if [ -n "$_allow" ]; then
      case " $_allow " in *" $_key "*) ;; *) continue ;; esac
    fi
    if [ -z "${!_key+x}" ]; then
      export "$_key=$_val"
      eval "$_record=\"\${$_record:+\${$_record} }\$_key\""
    fi
  done < "$_f"
}

_dev_env_layer "${DEV_ENV_FILE:-$_dev_env_root/stack/dev.env}" DEV_ENV_DEFAULTED ""

# One named path rather than a loop over three hypothetical ones: frontend/ and infra/
# have no such file today, and docs/adr/0006 says generalise when the second one exists.
_dev_env_layer "${SUBMODULE_ENV_FILE:-$_dev_env_root/chatbot-backend/.env}" \
  SUBMODULE_ENV_DEFAULTED "$SUBMODULE_ENV_ALLOW"

# The joined stack's credentials file, for its MODE SELECTORS ONLY — see SECRETS_ENV_ALLOW.
# Recorded separately from the other two because "where did this value come from" decides
# whether verify.sh may run a remote pass, and this one means "a real local credential set
# is configured", which is neither a committed placeholder nor a submodule's own file.
_dev_env_layer "$_dev_env_root/stack/secrets.env" \
  SECRETS_ENV_DEFAULTED "$SECRETS_ENV_ALLOW"

export DEV_ENV_DEFAULTED="${DEV_ENV_DEFAULTED:-}"
export SECRETS_ENV_DEFAULTED="${SECRETS_ENV_DEFAULTED:-}"
export SUBMODULE_ENV_DEFAULTED="${SUBMODULE_ENV_DEFAULTED:-}"

unset _dev_env_root
unset -f _dev_env_layer
