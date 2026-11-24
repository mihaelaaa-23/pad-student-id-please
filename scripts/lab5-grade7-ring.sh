#!/usr/bin/env bash
# Lab 5, grades 6 and 7: the Gateway's response cache, sharded over cache-1..3 by a
# consistent-hash ring (160 virtual nodes per node).
#   300 distinct cached responses are spread over the three nodes. cache-3 is stopped: only
#   the keys it held miss (the Gateway ejects it and its keys move to the next node on the
#   ring); every key on cache-1 and cache-2 is still a HIT. cache-3 is started again: it is
#   flushed and put back on the ring.
#
#   bash scripts/lab5-grade7-ring.sh           (NONINTERACTIVE=1 to skip the pauses)
#
# The 300 keys are one applicant read with 300 different query strings (the query is part of
# the cache key). The entries live 60 s (the applicant route's TTL), so the steps from the
# warm-up to the re-read run without pauses.
source "$(dirname "$0")/lab5-lib.sh"

KEYS="${KEYS:-300}"
STOPPED_NODE="cache-3"

show_ring() {
  api GET /cache/ring "$SERVICE_TOKEN"
  expect_code 200
  python3 - "$BODY_FILE" <<'PY'
import json, sys
ring = json.load(open(sys.argv[1]))
print("vnodes per node: %s" % ring.get("vnodes"))
for n in ring.get("nodes", []):
    share = n.get("share")
    print("  %-8s %-5s keys=%-6s share=%s" % (n.get("node"), n.get("state"), n.get("keys"), "-" if share is None else "%.0f%%" % (share * 100)))
PY
}

node_state() {
  api_quiet GET /cache/ring "$SERVICE_TOKEN"
  python3 -c 'import json,sys; print({n["node"]: n["state"] for n in json.load(open(sys.argv[1]))["nodes"]}.get(sys.argv[2], ""))' "$BODY_FILE" "$1"
}

lookup() {
  api_quiet GET "/cache/ring/lookup?key=$1" "$SERVICE_TOKEN"
  jget node
}

# read_all FILE: GETs the KEYS keys, one line per key: "i X-Cache X-Cache-Node".
read_all() {
  local i
  : >"$1"
  for ((i = 1; i <= KEYS; i++)); do
    api_quiet GET "/applicant/applicants/$APPLICANT_ID?k=$i" "$SERVICE_TOKEN"
    [[ "$HTTP_CODE" == "200" ]] || die "GET /applicant/applicants/$APPLICANT_ID?k=$i answered $HTTP_CODE"
    echo "$i $(header X-Cache) $(header X-Cache-Node)" >>"$1"
  done
}

# Counts of "X-Cache node" pairs in a read_all file.
tally() { awk '{ print $2, $3 }' "$1" | sort | uniq -c | sed 's/^ */  /'; }

step "The ring: three Valkey nodes, all up"
show_ring
for node in cache-1 cache-2 cache-3; do
  [[ "$(node_state "$node")" == "up" ]] || die "$node is not up on the ring"
done

step "An applicant to read (its version key must not live on $STOPPED_NODE)"
# Stopping the node that holds ver:applicant:<id> would give the applicant a new version and
# make every one of its entries miss once, which is correct but hides what this demo shows.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  api POST /applicant/applicants "$SERVICE_TOKEN" "{\"name\":\"Ring Demo $(unique)\",\"studentId\":\"FCIM-$((RANDOM % 900000 + 100000))\",\"major\":\"Software Engineering\",\"year\":2,\"role\":\"student_faf\",\"status\":\"active\"}"
  expect_code 201
  APPLICANT_ID="$(jget applicantId)"
  on_exit "curl -s -o /dev/null -X DELETE -H 'Authorization: Bearer $SERVICE_TOKEN' '$BASE_URL/applicant/applicants/$APPLICANT_ID'"
  VERSION_NODE="$(lookup "ver:applicant:$APPLICANT_ID")"
  [[ -n "$VERSION_NODE" && "$VERSION_NODE" != "$STOPPED_NODE" ]] && break
  info "ver:applicant:$APPLICANT_ID is on $STOPPED_NODE, creating another applicant"
done
[[ "$VERSION_NODE" != "$STOPPED_NODE" ]] || die "could not find an applicant whose version key avoids $STOPPED_NODE"
show "curl \"$BASE_URL/cache/ring/lookup?key=ver:applicant:$APPLICANT_ID\" -H \"Authorization: Bearer \$SERVICE_TOKEN\""
ok "applicant $APPLICANT_ID, version key on $VERSION_NODE"

step "Warm $KEYS keys, stop $STOPPED_NODE, read the same $KEYS keys again (no pauses: the entries live 60 s)"
show "for i in \$(seq 1 $KEYS); do curl -s -o /dev/null -D - \"$BASE_URL/applicant/applicants/$APPLICANT_ID?k=\$i\" -H \"Authorization: Bearer \$SERVICE_TOKEN\" | grep -i '^x-cache'; done"
read_all "$TMP_DIR/warm.txt"
echo "First read (X-Cache, node):"
tally "$TMP_DIR/warm.txt"
awk '$2 != "MISS"' "$TMP_DIR/warm.txt" | grep -q . && die "the first read of a fresh key must be a MISS"
ON_STOPPED="$(awk -v n="$STOPPED_NODE" '$3 == n' "$TMP_DIR/warm.txt" | wc -l | tr -d ' ')"
(( ON_STOPPED > 0 )) || die "no key landed on $STOPPED_NODE"
ok "$KEYS entries stored, $ON_STOPPED of them on $STOPPED_NODE"

show_ring

run docker compose stop "$STOPPED_NODE"
on_exit "docker compose start $STOPPED_NODE"

show "(the same loop again)"
read_all "$TMP_DIR/after.txt"
echo "Second read, with $STOPPED_NODE stopped (X-Cache, node):"
tally "$TMP_DIR/after.txt"

python3 - "$TMP_DIR/warm.txt" "$TMP_DIR/after.txt" "$STOPPED_NODE" "${RING_FAILOPEN_TOLERANCE:-2}" <<'PY'
import sys
# A line is "i X-Cache [X-Cache-Node]"; the node is missing when the Gateway failed open
# (a cache call over CACHE_TIMEOUT_MS, 50 ms, is a MISS without a node, never an error).
def parse(path):
    return {l.split()[0]: (l.split() + ["", ""])[:3] for l in open(path) if l.strip()}
warm, after = parse(sys.argv[1]), parse(sys.argv[2])
stopped, tolerance = sys.argv[3], int(sys.argv[4])
bad = []
others_hit = moved_miss = fail_open = 0
for key, (_, _, node_before) in warm.items():
    _, cache, node_after = after[key]
    if node_before == "" or (cache == "MISS" and node_after == "" and node_before != stopped):
        fail_open += 1
        continue
    if node_before == stopped:
        if cache != "MISS":
            bad.append("k=%s was on %s but answered %s" % (key, stopped, cache))
        elif node_after != stopped:
            moved_miss += 1
    else:
        if cache != "HIT" or node_after != node_before:
            bad.append("k=%s on %s answered %s from %s" % (key, node_before, cache, node_after))
        else:
            others_hit += 1
print("keys on the other nodes still HIT on the same node: %d" % others_hit)
print("keys of the stopped node that MISS (re-stored on the next node of the ring): %d, the rest missed while it was being ejected" % moved_miss)
print("keys that failed open (a cache call over 50 ms, MISS without a node): %d, %d allowed" % (fail_open, tolerance))
if fail_open > tolerance:
    bad.append("%d keys failed open, more than the %d allowed" % (fail_open, tolerance))
if bad:
    print("unexpected:")
    print("\n".join("  " + b for b in bad[:10]))
    sys.exit(1)
PY
ok "only $STOPPED_NODE's keys missed"

step "The ring now: $STOPPED_NODE is down (ejected after 3 failed calls)"
show_ring
[[ "$(node_state "$STOPPED_NODE")" == "down" ]] || die "$STOPPED_NODE should be down on the ring"

step "Start $STOPPED_NODE again: the Gateway pings it, flushes it and puts it back"
run docker compose start "$STOPPED_NODE"
node_up() { [[ "$(node_state "$STOPPED_NODE")" == "up" ]]; }
wait_until 60 "$STOPPED_NODE is up on the ring again" node_up
show_ring

echo
ok "grade 7 demo done"
