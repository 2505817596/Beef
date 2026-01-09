#!/usr/bin/env bash
set -euo pipefail
ZIG=/cygdrive/d/zig-x86_64-windows-0.16.0-dev.238+580b6d1fa/zig.exe
args=()
for a in "$@"; do
  if [[ "$a" == /cygdrive/* ]]; then
    a=$(cygpath -w "$a")
  elif [[ "$a" == -I/cygdrive/* || "$a" == -L/cygdrive/* ]]; then
    prefix=${a:0:2}
    path=${a:2}
    path=$(cygpath -w "$path")
    a="${prefix}${path}"
  fi
  args+=("$a")
done
exec "$ZIG" cc --target=x86_64-linux-musl -fno-sanitize=all "${args[@]}"
