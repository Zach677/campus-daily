#!/bin/sh
# The two privacy checks to run before every commit. They read the staged
# content (the Git index), not the working tree, and print counts and
# file:line locations only, never the values themselves. Exit 1 on any hit.
#
#   1. Pattern scan: identifier-shaped values (phone numbers, long ids, MACs,
#      custid ciphertexts) in every tracked file except images and Vendor/.
#   2. Value scan: every line of your private value list (your own real
#      student id, phone, room, device ids, tokens, platform secret...) must
#      not appear in any tracked file, ignoring case.
#
# The value list lives outside Git. Its path comes from LEAKCHECK_FILE
# (default: private/capture/secrets/leakcheck.txt in the checkout). A missing
# list is a failure; pass --allow-missing to run only the pattern scan.
#
#   LEAKCHECK_FILE=/path/to/leakcheck.txt sh Scripts/privacy-check.sh [--allow-missing] [repo]
allow_missing=0
if [ "$1" = "--allow-missing" ]; then allow_missing=1; shift; fi
root=$(git rev-parse --show-toplevel) || exit 2
list=${LEAKCHECK_FILE:-$root/private/capture/secrets/leakcheck.txt}
cd "${1:-$root}" || exit 2
hits=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Staged text files, minus images and vendored binaries.
scan() { # extended-regex [-i]
  git grep --cached -I -n -o $2 -E "$1" -- . ':(exclude)Vendor' \
    ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.jpeg' ':(exclude)*.webp' 2>/dev/null
}
# Turn "file:line:match" into "file:line<TAB>match" so allowlists see only the value.
split() { sed 's/^\([^:]*:[0-9]*\):/\1	/'; }
report() { # label file-with-"loc<TAB>value"-lines
  n=$(wc -l < "$2" | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    echo "$1: $n"; cut -f1 "$2" | sort -u | head -20
    hits=$((hits+n))
  fi
}

# 1. Pattern scan. Digit rules look at whole digit runs, so the allowlists
#    are anchored on the complete value, never on the rest of the line.
scan '[0-9]{11,}' | split > "$tmp/digits"
# CN mobile (11 digits starting 1) other than the synthetic 13800000000
grep -E '	1[3-9][0-9]{9}$' "$tmp/digits" | grep -vE '	13800000000$' > "$tmp/phone"
report "phone-like" "$tmp/phone"
# 0-prefixed 11 digits (shape seen in real captures); synthetic ones contain 000000
grep -E '	0[0-9]{10}$' "$tmp/digits" | grep -vE '	[0-9]*000000[0-9]*$' > "$tmp/zero11"
report "0-prefixed 11 digits" "$tmp/zero11"
# 15+ digit ids (order numbers, card ids...). Synthetic ones contain a run of
# seven zeros, start 1700000000 / 1000000000 / 001001001 (fake building
# codes), contain the byte ramp 00010203040506, or are all nines.
grep -E '	[0-9]{15,}$' "$tmp/digits" \
  | grep -vE '	([0-9]*0000000[0-9]*|1700000000[0-9]*|1000000000[0-9]*|001001001[0-9]*|[0-9]*00010203040506[0-9]*|9+)$' > "$tmp/longid"
report "long numeric id" "$tmp/longid"
# MAC addresses other than 02:00:00:00:00:xx and the placeholders
# AA:BB:CC:DD:EE:FF / 11:22:33:44:55:66
scan '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | split \
  | grep -viE '	(02:00:00:00:00:[0-9a-f]{2}|aa:bb:cc:dd:ee:ff|11:22:33:44:55:66)$' > "$tmp/mac"
report "MAC" "$tmp/mac"
# custid/syscustid ciphertexts in any key/value shape (JSON, query, plist,
# code) unless clearly synthetic (TEST..., YOUR_OWN..., fict...)
scan '(sys)?custid["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/=_%-]{16,}' -i | split \
  | grep -viE '	[^	]*[:=][[:space:]]*["'"'"']?(TEST|YOUR_OWN|fict)' > "$tmp/custid"
report "custid ciphertext" "$tmp/custid"
echo "pattern scan: $hits suspicious"

# 2. Value scan
if [ -f "$list" ]; then
  # Drop CR, blank lines and short numbers (they match everywhere as substrings).
  tr -d '\r' < "$list" | grep -vE '^[[:space:]]*$|^[0-9]{1,5}$' > "$tmp/values"
  if [ -s "$tmp/values" ]; then
    git grep --cached -I -i -n -F -f "$tmp/values" -- . 2>/dev/null | cut -d: -f1,2 > "$tmp/leaks"
  else
    : > "$tmp/leaks"
  fi
  n=$(cut -d: -f1 "$tmp/leaks" | sort -u | grep -c .)
  echo "value scan: $(wc -l < "$tmp/values" | tr -d ' ') values, $n files with hits"
  [ "$n" -gt 0 ] && sort -u "$tmp/leaks" | head -50
  hits=$((hits+n))
elif [ "$allow_missing" -eq 1 ]; then
  echo "value scan: skipped (no list at LEAKCHECK_FILE; --allow-missing)"
else
  echo "value scan: list not found (set LEAKCHECK_FILE, or pass --allow-missing)" >&2
  exit 2
fi

[ "$hits" -eq 0 ]
