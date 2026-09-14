#!/bin/sh
# mutate.sh -- break each property the freshness-badge tests claim to hold, one
# at a time, and count how many CASES notice.
#
# HYPOTHESIS. The tests added for issue #18 test what they say they test.
# Falsifiable, and the falsification is cheap: any mutation that SURVIVES --
# zero cases fail -- is a property with no test behind it, and the suite's
# green says nothing about it.
#
# WHY GREEN IS NOT ENOUGH, FOR THIS CHANGE IN PARTICULAR. The valuable
# assertion is that plp and pdp AGREE about a badge, and agreement between two
# nulls is also agreement. A badge feature wired up nowhere at all passes a
# naive agreement test perfectly, every day, forever. So the mutation that
# matters most is `badge-never-derived`: delete the feature from both apps at
# once and see whether anything goes red. If that one survives, the assertion
# this whole change was written for is decorative.
#
# 015-marker-mutation is the same instrument pointed at the marker sink;
# 012-guard-mutation is it pointed at the control plane, where every mutation
# survived. That is the result this exists to avoid repeating.
#
#   run:     ./experiments/018-badge-mutation/mutate.sh
#   output:  experiments/018-badge-mutation/results.tsv
set -eu
cd "$(dirname "$0")/../.."
HERE=experiments/018-badge-mutation
OUT=$HERE/results.tsv
TABLE=$(mktemp)
trap 'rm -f "$TABLE"' EXIT

# name : suite : file : sed expression that breaks the property.
# `suite` selects which cases get to notice; `all` is every app suite plus the
# shared one, and is used for mutations that should be caught in more than one
# place at once.
cat > "$TABLE" <<'ROWS'
badge-never-derived:all:shared/oneui.js:s/^export function productBadge(p, now = Date.now()) {$/export function productBadge(p, now = Date.now()) { return null;/
badge-never-expires:all:shared/oneui.js:s/const fresh = (day) => day !== null \&\& t >= day \&\& t - day < window;/const fresh = (day) => day !== null;/
future-date-is-new:shared:shared/oneui.js:s/const fresh = (day) => day !== null \&\& t >= day \&\& t - day < window;/const fresh = (day) => day !== null \&\& t - day < window;/
updated-outranks-newer-added:shared:shared/oneui.js:s/if (fresh(updated) \&\& (added === null || updated >= added)) return/if (fresh(updated) || false) return/
loose-date-parsing:shared:shared/oneui.js:s|if (!m) return null;|if (!m) return Number.isNaN(Date.parse(s)) ? null : Date.parse(s);|
badge-html-unescaped:shared:shared/oneui.js:s|<span class=b>${esc(label)}</span>|<span class=b>${label}</span>|
pdp-does-not-render:pdp:apps/pdp/src/server.js:s|<h2>${badgeHtml(p.badge)}${esc(p.name)}</h2>|<h2>${esc(p.name)}</h2>|
pdp-badge-not-in-payload:pdp:apps/pdp/src/server.js:s/badge: productBadge(hit, now),/badge: null,/
plp-does-not-render:plp:apps/plp/src/server.js:s#${badgeHtml(p.badge)}${esc(p.name || p.sku)}#${esc(p.name || p.sku)}#
plp-keeps-its-own-rule:estate:apps/plp/src/server.js:s/badge: byS.has(s) ? productBadge(byS.get(s), now) : null,/badge: byS.has(s) ? productBadge(byS.get(s), now - 40 * 86400000) : null,/
plp-search-drops-the-badge:plp:apps/plp/src/server.js:s/({ sku: r.sku, name: r.name, badge: r.badge })/({ sku: r.sku, name: r.name, badge: null })/
ROWS

# How many CASES fail. The COUNT matters, not just the kill: a mutation killed
# by exactly one case is one edit away from being killed by none.
failures() {
  case "$1" in
    shared) out=$(node --test shared/tests/*.test.mjs 2>&1 || true) ;;
    pdp)    out=$(cd apps/pdp && node --test tests/unit/product.test.js 2>&1 || true) ;;
    plp)    out=$(cd apps/plp && node --test tests/unit/listing.test.js 2>&1 || true) ;;
    estate) out=$(cd apps/pdp && node --test tests/unit/estate.test.js 2>&1 || true) ;;
    all)    out=$( { node --test shared/tests/*.test.mjs 2>&1 || true
                     (cd apps/pdp && node --test tests/unit/*.test.js 2>&1 || true)
                     (cd apps/plp && node --test tests/unit/*.test.js 2>&1 || true); } ) ;;
    *)      echo "unknown suite $1" >&2; exit 2 ;;
  esac
  printf '%s\n' "$out" | sed -n 's/^..fail \([0-9][0-9]*\)$/\1/p' \
    | awk '{n += $1} END {print n + 0}'
}

printf 'name\tsuite\tcases_failed\tverdict\n' > "$OUT"

while IFS=: read -r name suite file expr; do
  [ -n "$name" ] || continue
  cp "$file" "$file.orig"
  sed "$expr" "$file.orig" > "$file"
  # A MUTATION THAT DID NOT CHANGE THE FILE TESTS NOTHING, and reporting it as
  # killed is the failure mode of every mutation harness -- the harness passes
  # and has run no experiment. It is counted as survived, loudly.
  if cmp -s "$file" "$file.orig"; then
    mv "$file.orig" "$file"
    printf '%s\t%s\t-\tNOT APPLIED\n' "$name" "$suite" >> "$OUT"
    printf '%-30s %-7s %-3s %s\n' "$name" "$suite" '-' 'NOT APPLIED -- sed matched nothing'
    continue
  fi
  n=$(failures "$suite")
  mv "$file.orig" "$file"
  if [ "$n" -gt 0 ]; then v=killed; else v=SURVIVED; fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$suite" "$n" "$v" >> "$OUT"
  printf '%-30s %-7s %-3s %s\n' "$name" "$suite" "$n" "$v"
done < "$TABLE"

echo
awk -F'\t' 'NR>1 {t++; if ($4=="killed") k++} END {
  printf "  %d mutations, %d killed, %d not killed\n", t, k+0, t-(k+0) }' "$OUT"
echo "results in $OUT"
echo "A row with cases_failed 0 is a property nothing tests. A row with 1 is one"
echo "edit away from being that."
