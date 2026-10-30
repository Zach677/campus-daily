#!/bin/sh
# The two privacy checks to run before every commit. Prints counts and
# file:line locations only, never the values themselves. Exit 1 on any hit.
#
#   1. Pattern scan: identifier-shaped values (phone numbers, long ids, MACs,
#      custid ciphertexts) in test sources, fixtures and docs.
#   2. Value scan: every line of private/leakcheck.txt (Git-ignored; your own
#      real student id, phone, room, device ids, tokens, platform secret...)
#      must not appear in any tracked or staged file.
cd "${1:-$(git rev-parse --show-toplevel)}" || exit 2
hits=0

# 1. Pattern scan
files=$(git ls-files -co --exclude-standard Packages/Core/Tests Scripts/Tests docs | grep -vE '\.(png|jpg)$')
check() { # label regex allowlist-regex
  n=$(echo "$files" | xargs grep -nEo "$2" 2>/dev/null | grep -vE "$3" | wc -l)
  if [ "$n" -gt 0 ]; then
    echo "$1: $n"; echo "$files" | xargs grep -nEo "$2" 2>/dev/null | grep -vE "$3" | cut -d: -f1,2 | sort -u | head -20
    hits=$((hits+n))
  fi
}
# CN mobile (11 digits starting 1) other than the synthetic 13800000000
check "phone-like" '(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)' '13800000000'
# 0-prefixed 11 digits (shape seen in real captures)
check "0-prefixed 11 digits" '(^|[^0-9])0[0-9]{10}([^0-9]|$)' '000000'
# 15-20 digit ids without long zero runs (synthetic ones use 000000)
check "long numeric id" '[0-9]{15,20}' '0000000|1700000000|1000000000|2026[0-9]{6}|[0-9]{13}\b'
# MAC addresses other than 02:00:00:...
check "MAC" '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' '02:00:00:00:00:'
# custid/syscustid ciphertexts not starting TEST
check "custid ciphertext" '"(sys)?custid": *"[^"T][^"]{15,}"' 'YOUR_OWN|fict'
echo "pattern scan: $hits suspicious"

# 2. Value scan
list=private/leakcheck.txt
if [ -f "$list" ]; then
  values=$(mktemp); trap 'rm -f "$values"' EXIT
  # Skip blank lines and short numbers (they match everywhere as substrings).
  grep -vE '^\s*$|^[0-9]{1,5}$' "$list" > "$values"
  leaked=$(git ls-files -co --exclude-standard | grep -v '^private/' | while IFS= read -r f; do
    [ -f "$f" ] && grep -qF -f "$values" "$f" 2>/dev/null && echo "$f"
  done)
  n=$(printf '%s' "$leaked" | grep -c .)
  echo "value scan: $(wc -l < "$values" | tr -d ' ') values, $n files with hits"
  [ "$n" -gt 0 ] && echo "$leaked"
  hits=$((hits+n))
else
  echo "value scan: skipped (create $list with one real value per line)"
fi

[ "$hits" -eq 0 ]
