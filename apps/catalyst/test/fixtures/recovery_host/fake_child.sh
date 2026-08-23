#!/bin/sh

set -u

atomic_ready() {
  temporary="${CATALYST_RECOVERY_READY_PATH}.tmp.$$"
  profile=$(tr -d '\r\n' <"$CATALYST_HOME/product_profile")
  printf '%s:%s\n' "$CATALYST_RECOVERY_BOOT_TOKEN" "$profile" >"$temporary"
  mv -f "$temporary" "$CATALYST_RECOVERY_READY_PATH"
}

case "${TEST_RECOVERY_SCENARIO:-}" in
  ready)
    atomic_ready
    exit 0
    ;;
  ready_failure)
    atomic_ready
    exit 5
    ;;
  profile_mismatch)
    count_path="$TEST_RECOVERY_STATE/count"
    count=0
    [ -f "$count_path" ] && count=$(cat "$count_path")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_path"

    if [ "$count" -eq 1 ]; then
      temporary="${CATALYST_RECOVERY_READY_PATH}.tmp.$$"
      printf '%s:coding-agent\n' "$CATALYST_RECOVERY_BOOT_TOKEN" >"$temporary"
      mv -f "$temporary" "$CATALYST_RECOVERY_READY_PATH"
    else
      atomic_ready
    fi

    exit 0
    ;;
  rollback)
    count_path="$TEST_RECOVERY_STATE/count"
    count=0
    [ -f "$count_path" ] && count=$(cat "$count_path")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_path"

    if [ "$count" -eq 1 ]; then
      exit 7
    fi

    [ "${CATALYST_SAFE_MODE:-}" = 1 ] || exit 8
    [ "$(tr -d '\r\n' <"$CATALYST_HOME/product_profile")" = "$EXPECTED_PROFILE" ] || exit 9
    atomic_ready
    exit 0
    ;;
  rollback_signal)
    count_path="$TEST_RECOVERY_STATE/count"
    count=0
    [ -f "$count_path" ] && count=$(cat "$count_path")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_path"

    if [ "$count" -eq 1 ]; then
      exit 7
    fi

    trap 'printf "term\n" >"$TEST_RECOVERY_STATE/child_signal"; exit 0' TERM
    atomic_ready
    printf 'child-ready\n'

    while :; do
      sleep 1
    done
    ;;
  signal)
    trap 'printf "term\n" >"$TEST_RECOVERY_STATE/child_signal"; exit 0' TERM
    atomic_ready
    printf 'child-ready\n'

    while :; do
      sleep 1
    done
    ;;
  *)
    exit 10
    ;;
esac
