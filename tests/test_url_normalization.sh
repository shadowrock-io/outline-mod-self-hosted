#!/usr/bin/env bash
# URL normalization test suite — runs in CI and locally.
set -euo pipefail

PASS=0
FAIL=0

# Extract normalize_url from the main script (avoids sourcing the whole thing)
eval "$(sed -n '/^normalize_url()/,/^}/p' "$(dirname "$0")/../outline-mod.sh")"

assert_eq() {
  local input="$1" expected="$2"
  local result
  result="$(normalize_url "$input")"
  if [[ "$result" == "$expected" ]]; then
    printf '  \033[0;32mPASS\033[0m  %-50s -> %s\n' "'$input'" "$result"
    PASS=$((PASS + 1))
  else
    printf '  \033[0;31mFAIL\033[0m  %-50s -> %s (expected %s)\n' "'$input'" "$result" "$expected"
    FAIL=$((FAIL + 1))
  fi
}

echo "URL Normalization Tests"
echo ""

# Basic
assert_eq "https://docs.example.com"          "https://docs.example.com"
assert_eq "https://docs.example.com/"         "https://docs.example.com"

# Case normalization
assert_eq "https://DOCS.Example.COM"          "https://docs.example.com"
assert_eq "HTTPS://docs.example.com"          "https://docs.example.com"
assert_eq "Http://Mixed.Case.Host:9090/path"  "http://mixed.case.host:9090"

# Port preservation
assert_eq "https://outline.company.io:8443"   "https://outline.company.io:8443"
assert_eq "https://docs.example.com:3000/login" "https://docs.example.com:3000"

# Path stripping
assert_eq "https://docs.example.com/path/stuff" "https://docs.example.com"
assert_eq "https://docs.example.com/a/b/c?q=1"  "https://docs.example.com"

# Scheme defaulting
assert_eq "docs.example.com"                  "https://docs.example.com"
assert_eq "docs.example.com:8443"             "https://docs.example.com:8443"

# Whitespace
assert_eq "  https://docs.example.com  "      "https://docs.example.com"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if (( FAIL > 0 )); then
  exit 1
fi
