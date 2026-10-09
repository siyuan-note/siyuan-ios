#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if ! command -v swift >/dev/null 2>&1; then
  echo "SKIP: Swift is not installed; policy behavior and WebKit integration are not verified." >&2
  exit 77
fi
file=$(mktemp -t NativeBridgePolicy.XXXXXX.swift)
trap 'rm -f "$file"' EXIT
python3 - "$file" <<'PY'
import pathlib, sys
source = pathlib.Path('siyuan-ios/ViewController.swift').read_text()
policy = source[source.index('enum NativeBridgePolicy {'):source.index('\nclass ViewController:')]
pathlib.Path(sys.argv[1]).write_text('import Foundation\n' + policy + '\n' + pathlib.Path('tests/NativeBridgePolicyTests.swift').read_text())
PY
swift "$file"
