# claude-smoke-test [path/to/claude]
#
# Runs one complete headless turn (`claude -p`) against a local mock of the
# Messages API. No token or network is needed, no usage is billed. Exit 0 only
# if Claude Code starts, sends a request and prints the mocked answer.
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

    port=$(( 20000 + RANDOM % 20000 ))
    python3 -I ${./mock-anthropic-api.py} "$port" 2>"$work/mock.log" &
    mock_pid=$!
    for _ in $(seq 50); do
      (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break
      sleep 0.2
    done

    # shellcheck disable=SC2086
    if ! out=$(env -i PATH="$PATH" HOME="$work" \
        ANTHROPIC_API_KEY=sk-smoke-test \
        ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
        DISABLE_AUTOUPDATER=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        timeout 600 ''${SMOKE_PREFIX:-} "$claude_bin" -p "smoke test" </dev/null 2>&1); then
      echo "claude-smoke-test: FAILED (exit $?)" >&2
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
