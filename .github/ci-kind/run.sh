#!/usr/bin/env bash
# Scratch CI for PR #115: apply ROS2/jazzy/pulse-talker-listener.yaml to a 3-node kind cluster
# and record placement, restarts, memory, logs and the /chatter series from each pulse-export
# sidecar through kubectl port-forward.
#   phase a: the manifest exactly as in the PR (default Fast DDS discovery, scheduler placement)
#   phase s: CI-only, same manifest with both pods pinned to one worker
#   phase b: CI-only overlay, not part of the PR: a Fast DDS discovery server in the same
#            namespace, ROS_DISCOVERY_SERVER on both ROS containers, talker and listener pinned
#            to different workers (same approach as #97)
set -uo pipefail

CLUSTER=ros2k8s-demo
CTX="kind-$CLUSTER"
NS=ros2-pulse-pilot
OUT="${OUT:-$PWD/out}"
mkdir -p "$OUT"
k() { kubectl --context "$CTX" "$@"; }
log() { printf '\n=== %s\n' "$*"; }

scrape() { # phase deployment localport
  local p=$1 d=$2 port=$3 ok=0 pf
  k -n "$NS" port-forward "deploy/$d" "$port:9464" > "$OUT/$p-$d-port-forward.log" 2>&1 &
  pf=$!
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 3 "http://127.0.0.1:$port/metrics" > "$OUT/$p-$d-metrics.txt" 2>/dev/null; then
      ok=1; break
    fi
    sleep 1
  done
  kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null
  log "$p: $d /metrics via kubectl port-forward (ok=$ok)"
  cat "$OUT/$p-$d-port-forward.log"
  grep -F 'topic="/chatter"' "$OUT/$p-$d-metrics.txt" || echo "(no /chatter series)"
  echo "$p $d port_forward_ok=$ok" >> "$OUT/port-forward-results.txt"
}

snapshot() { # phase
  local p=$1 d c
  log "$p: pods -o wide"
  k -n "$NS" get pods -o wide | tee "$OUT/$p-pods-wide.txt"
  log "$p: restarts and last termination reason"
  k -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" node="}{.spec.nodeName}{" podIP="}{.status.podIP}{"\n"}{range .status.containerStatuses[*]}{"  "}{.name}{" ready="}{.ready}{" restarts="}{.restartCount}{" lastTerminated="}{.lastState.terminated.reason}{"\n"}{end}{end}' \
    | tee "$OUT/$p-restarts.txt"
  scrape "$p" pulse-talker 19464
  scrape "$p" pulse-listener 19465
  for d in pulse-talker pulse-listener; do
    c=${d#pulse-}
    log "$p: $d ROS process (pid 1 of container $c): open-files limit and RSS"
    k -n "$NS" exec "deploy/$d" -c "$c" -- sh -c 'grep -i "open files" /proc/1/limits; grep -E "VmRSS|VmHWM" /proc/1/status' \
      | tee "$OUT/$p-$d-proc.txt"
    log "$p: $d last two probe windows (jsonl)"
    k -n "$NS" exec "deploy/$d" -c pulse-export -- sh -c 'ls -l /var/log/ros2_pulse; tail -n 2 /var/log/ros2_pulse/*.jsonl' \
      | tee "$OUT/$p-$d-jsonl-tail.txt"
    k -n "$NS" logs "deploy/$d" -c "$c" > "$OUT/$p-$d-$c.log" 2>&1
    k -n "$NS" logs "deploy/$d" -c pulse-export > "$OUT/$p-$d-pulse-export.log" 2>&1
  done
  log "$p: log line counts"
  {
    echo "talker 'Publishing:' lines: $(grep -c 'Publishing:' "$OUT/$p-pulse-talker-talker.log")"
    echo "listener 'I heard:' lines: $(grep -c 'I heard:' "$OUT/$p-pulse-listener-listener.log")"
    echo "talker probe banner: $(grep -F '[ros2_pulse]' "$OUT/$p-pulse-talker-talker.log" | head -n 2)"
    echo "listener probe banner: $(grep -F '[ros2_pulse]' "$OUT/$p-pulse-listener-listener.log" | head -n 2)"
  } | tee "$OUT/$p-log-counts.txt"
  log "$p: container memory per node (crictl stats)"
  for n in $(kind get nodes --name "$CLUSTER"); do
    echo "-- $n"; docker exec "$n" crictl stats 2>/dev/null
  done | tee "$OUT/$p-crictl-stats.txt"
  log "$p: events"
  k -n "$NS" get events --sort-by=.lastTimestamp | tee "$OUT/$p-events.txt"
}

log "versions"
{
  echo "runner arch: $(uname -m)"
  docker version --format 'docker server {{.Server.Version}}'
  kind version
  kubectl version --context "$CTX"
  k get nodes -o wide
} 2>&1 | tee "$OUT/versions.txt"

log "phase a: apply ROS2/jazzy/pulse-talker-listener.yaml unchanged"
k apply -f ROS2/jazzy/pulse-talker-listener.yaml
k -n "$NS" rollout status deploy/pulse-talker --timeout=180s
k -n "$NS" rollout status deploy/pulse-listener --timeout=180s
date -u +"phase a ready %FT%TZ" | tee -a "$OUT/timeline.txt"
sleep 60
snapshot a
log "phase a: hold another 120 s to watch for restarts or memory growth"
sleep 120
snapshot a2

log "phase s (CI-only): unchanged manifest, default discovery, both pods pinned to the same worker"
for d in pulse-talker pulse-listener; do
  k -n "$NS" patch "deploy/$d" --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"ros2k8s-demo/role":"talker"}}}}}'
done
k -n "$NS" rollout status deploy/pulse-talker --timeout=180s
k -n "$NS" rollout status deploy/pulse-listener --timeout=180s
date -u +"phase s ready %FT%TZ" | tee -a "$OUT/timeline.txt"
sleep 60
snapshot s

log "phase b (CI-only overlay): discovery server + ROS_DISCOVERY_SERVER + different workers"
k apply -f .github/ci-kind/discovery-server.yaml
k -n "$NS" rollout status deploy/discovery-server --timeout=180s
ds=discovery-server.$NS.svc.cluster.local:11811
k -n "$NS" set env deploy/pulse-talker -c talker "ROS_DISCOVERY_SERVER=$ds"
k -n "$NS" set env deploy/pulse-listener -c listener "ROS_DISCOVERY_SERVER=$ds"
k -n "$NS" patch deploy/pulse-talker --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"ros2k8s-demo/role":"talker"}}}}}'
k -n "$NS" patch deploy/pulse-listener --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"ros2k8s-demo/role":"listener"}}}}}'
k -n "$NS" rollout status deploy/pulse-talker --timeout=180s
k -n "$NS" rollout status deploy/pulse-listener --timeout=180s
date -u +"phase b ready %FT%TZ" | tee -a "$OUT/timeline.txt"
sleep 60
snapshot b

log "summary"
{
  cat "$OUT/timeline.txt"
  for p in a a2 s b; do
    echo "--- phase $p"
    cat "$OUT/$p-restarts.txt"
    for d in pulse-talker pulse-listener; do
      echo "$d:"; grep -F 'topic="/chatter"' "$OUT/$p-$d-metrics.txt" | grep -E 'rate_hertz|_total' || echo "  (no /chatter series)"
      grep -E 'VmRSS|open files' "$OUT/$p-$d-proc.txt"
    done
    cat "$OUT/$p-log-counts.txt"
  done
  cat "$OUT/port-forward-results.txt"
} | tee "$OUT/summary.txt"

# Gate only on what the PR claims: pods run, port-forward works, the talker sidecar serves
# /chatter publishes. Listener callbacks are required only in the overlay phase.
rc=0
positive() { # file metric
  awk -v m="$2{" 'index($1, m) == 1 && index($1, "topic=\"/chatter\"") && $2 + 0 > 0 { ok = 1 } END { exit !ok }' "$1"
}
grep -q 'port_forward_ok=0' "$OUT/port-forward-results.txt" && { echo "FAIL: a port-forward scrape failed"; rc=1; }
positive "$OUT/a-pulse-talker-metrics.txt" ros2_pulse_topic_publish_rate_hertz \
  || { echo "FAIL: phase a talker has no positive /chatter publish rate"; rc=1; }
positive "$OUT/b-pulse-listener-metrics.txt" ros2_pulse_topic_receive_rate_hertz \
  || { echo "FAIL: phase b listener has no positive /chatter receive rate"; rc=1; }
exit "$rc"
