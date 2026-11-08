# claude-smoke-test [path/to/claude]
#
# Runs one complete headless turn (`claude -p`) against a local mock of the
# Messages API. No token or network is needed, no usage is billed. Exit 0 only
# if Claude Code starts, sends a request and prints the mocked answer; exit 2
# if the mock API itself could not start.
#
# SMOKE_PREFIX is prepended to the command, e.g. "qemu-x86_64 -cpu Westmere"
# to emulate a CPU without AVX in CI.
{
  writeShellApplication,
  python3,
  coreutils,
  gnugrep,
}:
writeShellApplication {
  name = "claude-smoke-test";
  runtimeInputs = [
    python3
    coreutils
    gnugrep
  ];
  text = ''
    claude_bin="''${1:-claude}"
    work=$(mktemp -d)
    trap 'kill "$mock_pid" 2>/dev/null || true; rm -rf "$work"' EXIT

    # The mock binds a free port itself and prints it once it is listening.
    python3 -I ${./mock-anthropic-api.py} >"$work/port" 2>"$work/mock.log" &
    mock_pid=$!
    port=""
    for _ in $(seq 150); do
      port=$(cat "$work/port")
      [ -n "$port" ] && break
      kill -0 "$mock_pid" 2>/dev/null || break
      sleep 0.2
    done
    if [ -z "$port" ]; then
      # Exit 2: the harness failed, not Claude Code.
      echo "claude-smoke-test: mock API did not start" >&2
      tail -20 "$work/mock.log" >&2
      exit 2
    fi

    rc=0
    # shellcheck disable=SC2086
    out=$(env -i PATH="$PATH" HOME="$work" \
        ANTHROPIC_API_KEY=sk-smoke-test \
        ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
        DISABLE_AUTOUPDATER=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        timeout 600 ''${SMOKE_PREFIX:-} "$claude_bin" -p "smoke test" </dev/null 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "claude-smoke-test: FAILED (exit $rc)" >&2
      echo "$out" | tail -20 >&2
      exit 1
    fi
    if ! grep -q GATE-OK <<<"$out"; then
      echo "claude-smoke-test: FAILED (unexpected output)" >&2
      echo "$out" | tail -20 >&2
      exit 1
    fi
    echo "claude-smoke-test: OK"
  '';
}
