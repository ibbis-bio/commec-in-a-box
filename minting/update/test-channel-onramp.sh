#!/usr/bin/env bash
# Regression test for the primary-channel onramp in commec-update-check.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$HERE/commec-update-check"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/env" "$TEST_ROOT/runtime"
touch "$TEST_ROOT/firstboot.done"
printf 'online\n' > "$TEST_ROOT/probe"

cat > "$TEST_ROOT/bin/conda" <<'SH'
#!/usr/bin/env bash
set -u

case "${1:-}" in
  list)
    printf '[{"name":"commec","version":"%s"}]\n' "$INSTALLED_VERSION"
    ;;
  search)
    printf '%s\n' "$*" >> "$FAKE_CONDA_LOG"
    if [[ " $* " == *" -c ibbis "* && " $* " != *" -c bioconda "* ]]; then
      if [ "${PRIMARY_ERROR:-0}" = 1 ]; then
        printf '{"exception_name":"CondaHTTPError","error":"primary failed"}\n'
        exit 1
      fi
      version="${PRIMARY_VERSION:-}"
    else
      version="${FALLBACK_VERSION:-}"
    fi
    if [ -z "$version" ]; then
      printf '{"exception_name":"PackagesNotFoundError","error":"PackagesNotFoundError"}\n'
      exit 1
    fi
    printf '{"commec":[{"name":"commec","version":"%s"}]}\n' "$version"
    ;;
  *)
    printf 'unexpected conda command: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod 0755 "$TEST_ROOT/bin/conda"

cat > "$TEST_ROOT/update.conf" <<EOF
commec_primary_channel=ibbis
conda_channels=ibbis,conda-forge,bioconda
probe_url=file://$TEST_ROOT/probe
db_update_enabled=0
EOF

run_case() { # <name> <primary version> <fallback version> <primary error> <token> <source> <searches>
  local name="$1" primary="$2" fallback="$3" primary_error="$4"
  local expected_token="$5" expected_source="$6" expected_searches="$7" token searches
  rm -f "$TEST_ROOT/runtime/commec-update."* "$TEST_ROOT/conda.log"
  : > "$TEST_ROOT/conda.log"

  token=$(INSTALLED_VERSION=2.1.0.dev1 PRIMARY_VERSION="$primary" \
    FALLBACK_VERSION="$fallback" PRIMARY_ERROR="$primary_error" \
    FAKE_CONDA_LOG="$TEST_ROOT/conda.log" XDG_RUNTIME_DIR="$TEST_ROOT/runtime" \
    COMMEC_CONDA="$TEST_ROOT/bin/conda" COMMEC_BASE_PYTHON="${TEST_PYTHON:-python3}" \
    COMMEC_ENV_LINK="$TEST_ROOT/env" COMMEC_BOX_CONF="$TEST_ROOT/update.conf" \
    COMMEC_FIRSTBOOT_GUARD="$TEST_ROOT/firstboot.done" "$CHECK" | tail -1)

  [ "$token" = "$expected_token" ] || {
    printf '%s: token %s, expected %s\n' "$name" "$token" "$expected_token" >&2
    exit 1
  }
  searches=$(wc -l < "$TEST_ROOT/conda.log")
  [ "$searches" -eq "$expected_searches" ] || {
    printf '%s: %s searches, expected %s\n' "$name" "$searches" "$expected_searches" >&2
    exit 1
  }

  if [ "$expected_token" != offline ]; then
    "${TEST_PYTHON:-python3}" - "$TEST_ROOT/runtime/commec-update.json" \
      "$expected_source" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    state = json.load(fh)
assert state["commec"]["source"] == sys.argv[2], state
PY
  fi
  printf 'ok: %s\n' "$name"
}

run_case empty-primary-falls-back "" 2.0.0 0 up-to-date fallback 2
run_case primary-is-authoritative 2.1.0 9.9.9 0 available:sw=2.1.0 ibbis 1
run_case older-primary-still-authoritative 2.0.0 9.9.9 0 up-to-date ibbis 1
run_case primary-error-is-offline "" 2.1.0 1 offline "" 1
