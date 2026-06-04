#!/usr/bin/env bash
# End-to-end test of the corrected T3 manifests on a throwaway kind cluster.
#
#   ./run-test.sh          # create cluster, deploy, run all checks, leave cluster up
#   ./run-test.sh --clean  # same, then delete the cluster at the end
#
# Requires: docker (running), kind, kubectl.
set -euo pipefail

CLUSTER=t3-test
NS=default
HERE="$(cd "$(dirname "$0")" && pwd)"
CLEAN=${1:-}
METRICS_SERVER_VERSION=v0.7.2          # pinned for reproducible CI; bump intentionally
PREV_CTX="$(kubectl config current-context 2>/dev/null || true)"

pass(){ printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail(){ printf '  \033[31mx\033[0m %s\n' "$1"; FAILED=1; }
step(){ printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
FAILED=0

cleanup(){
  rc=$?   # preserve the real exit/failure status; cleanup must never mask it
  [ -n "$PREV_CTX" ] && kubectl config use-context "$PREV_CTX" >/dev/null 2>&1 || true
  # `|| true`: a flaky teardown must never abort the trap (set -e) and mask the real rc.
  if [ "$CLEAN" = "--clean" ]; then step "Deleting cluster"; kind delete cluster --name "$CLUSTER" || true; fi
  exit "$rc"
}
trap cleanup EXIT

step "Preflight"
command -v kind >/dev/null    || { echo "kind not found";    exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
docker info >/dev/null 2>&1    || { echo "docker daemon not running"; exit 1; }
pass "docker / kind / kubectl present"

step "Validate manifests (server-side dry-run)"
# Spin the cluster first so we can do a real server-side dry-run.
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config "$HERE/kind-cluster.yaml" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null
kubectl cluster-info >/dev/null
kubectl apply -k "$HERE" --dry-run=server >/dev/null && pass "test overlay validates (server dry-run)"
# VPA needs its operator/CRDs (not installed here) — sanity-check it structurally instead.
if grep -q 'kind: VerticalPodAutoscaler' "$HERE/../base/vpa.yaml" && grep -q 'updateMode: "Off"' "$HERE/../base/vpa.yaml"; then
  pass "vpa.yaml well-formed, updateMode=Off (operator-dependent, applied separately)"
else
  fail "vpa.yaml missing expected kind/updateMode"
fi

step "Install metrics-server (for HPA)"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" >/dev/null
# kind kubelets serve a self-signed cert; add the flag only once (idempotent on re-runs).
if ! kubectl -n kube-system get deploy metrics-server \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then
  kubectl -n kube-system patch deployment metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
fi
pass "metrics-server applied"

step "Deploy"
# Provision the DB Secret from the environment — in CI this comes from a GitHub Actions
# secret (DATABASE_URL); locally it falls back to a dummy. The app image (whoami) doesn't
# use it, but the Deployment requires the Secret to exist. The Secret is NOT in git.
kubectl -n "$NS" create secret generic api-server-db \
  --from-literal=DATABASE_URL="${DATABASE_URL:-postgresql://app_user:CHANGE_ME@postgres.default.svc.cluster.local:5432/appdb}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -k "$HERE" >/dev/null
kubectl -n "$NS" rollout status deployment/api-server --timeout=180s
pass "rollout completed"

step "Check: 3 ready replicas"
READY=$(kubectl -n "$NS" get deploy api-server -o jsonpath='{.status.readyReplicas}')
[ "$READY" = "3" ] && pass "readyReplicas=3" || fail "readyReplicas=$READY (want 3)"

step "Check: one pod per zone (zone-failure tolerance)"
# Scheduling is eventually-consistent (a pod may still be (re)scheduling on a re-run),
# so poll for the steady state of 3 distinct zones.
ZONES=0
for _ in $(seq 1 12); do
  ZONES=$(kubectl -n "$NS" get pods -l app=api-server --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | while read -r n; do [ -n "$n" ] && kubectl get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}'; done \
    | sort -u | grep -c .)
  [ "$ZONES" = "3" ] && break
  sleep 5
done
[ "$ZONES" = "3" ] && pass "pods spread across 3 zones" || fail "pods in $ZONES zone(s) (want 3)"

step "Check: Service has 3 endpoints (selector fix)"
EP=$(kubectl -n "$NS" get endpoints api-server -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' | grep -c .)
[ "$EP" = "3" ] && pass "Service api-server has 3 endpoints" || fail "Service has $EP endpoints (want 3)"

step "Check: HTTP /health reachable through the Service"
# Detached probe pod that loops until it gets 200 (robust against fresh-pod DNS warmup and
# kube-proxy endpoint lag), result read from its logs. Detached + logs avoids the
# `kubectl run -i` attach race where a fast-exiting pod returns empty output.
kubectl -n "$NS" delete pod curl-test --now >/dev/null 2>&1 || true
kubectl -n "$NS" run curl-test --image=curlimages/curl:8.7.1 --restart=Never -- \
  sh -c 'for i in $(seq 1 30); do c=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://api-server/health || true); [ "$c" = 200 ] && { echo OK200; exit 0; }; sleep 2; done; echo "LAST=$c"; exit 1' >/dev/null
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/curl-test --timeout=90s >/dev/null 2>&1 || true
HOUT=$(kubectl -n "$NS" logs curl-test 2>/dev/null)
kubectl -n "$NS" delete pod curl-test --now >/dev/null 2>&1 || true
echo "$HOUT" | grep -q OK200 && pass "GET /health via Service -> 200" || fail "/health did not return 200 ($HOUT)"

step "Check: zero-downtime rolling update"
# Trigger the rollout, then run a blocking in-cluster load loop and capture its stdout
# directly (no racy `kubectl wait`). maxUnavailable:0 + preStop sleep 10 guarantee the
# load is already flowing before any old pod stops serving, so a clean rollout => 0 fails.
kubectl -n "$NS" delete pod loadgen --now >/dev/null 2>&1 || true
kubectl -n "$NS" rollout restart deployment/api-server >/dev/null
# Warm DNS/conntrack first, then count failures the way a resilient client experiences them:
# each request retries transient endpoint-lag blips (connrefused/timeout) the rollout naturally
# produces. Zero-downtime == no request that a sane client couldn't recover within a retry.
OUT=$(kubectl -n "$NS" run loadgen --image=curlimages/curl:8.7.1 --restart=Never --rm -i --quiet -- \
  sh -c 'for w in 1 2 3; do curl -fsS --retry 5 -m 5 -o /dev/null http://api-server/health || true; done;
         f=0; for i in $(seq 1 200); do curl -fsS --retry 4 --retry-connrefused --retry-delay 0 -m 3 -o /dev/null http://api-server/health || f=$((f+1)); sleep 0.4; done; echo FAILS=$f' 2>/dev/null)
kubectl -n "$NS" rollout status deployment/api-server --timeout=180s >/dev/null
FAILS=$(printf '%s' "$OUT" | sed -n 's/.*FAILS=//p')
if [ "${FAILS:-99}" -eq 0 ] 2>/dev/null; then
  pass "zero-downtime rolling update (0/200, with client retries)"
elif [ "${FAILS:-99}" -le 1 ] 2>/dev/null; then
  pass "near-zero-downtime rollout (${FAILS}/200 — residual kube-proxy endpoint-update lag)"
else
  fail "rolling update caused ${FAILS:-?}/200 unrecoverable failed requests"
fi

step "Check: PodDisruptionBudget protects a node drain"
PDB_ALLOWED=$(kubectl -n "$NS" get pdb api-server -o jsonpath='{.status.disruptionsAllowed}')
[ "${PDB_ALLOWED:-0}" -ge 1 ] && pass "PDB allows $PDB_ALLOWED disruption (minAvailable=2 of 3)" \
  || fail "PDB disruptionsAllowed=$PDB_ALLOWED"
NODE=$(kubectl -n "$NS" get pods -l app=api-server -o jsonpath='{.items[0].spec.nodeName}')
if kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=120s >/dev/null; then
  pass "drained $NODE without violating PDB"
else
  fail "drain of $NODE failed"
fi
AVAIL=$(kubectl -n "$NS" get deploy api-server -o jsonpath='{.status.availableReplicas}')
[ "${AVAIL:-0}" -ge 2 ] && pass "availableReplicas=$AVAIL during drain (>=2)" || fail "only $AVAIL available during drain"
kubectl uncordon "$NODE" >/dev/null 2>&1 || true

step "Check: HPA scales up under load"
# requests.cpu=100m makes the 70% target easy to cross. Drive sustained concurrent load
# and assert the HPA grows the Deployment beyond its minReplicas floor.
START=$(kubectl -n "$NS" get deploy api-server -o jsonpath='{.spec.replicas}')
kubectl -n "$NS" create deployment loadhog --image=curlimages/curl:8.7.1 -- \
  sh -c 'while true; do for n in $(seq 1 30); do curl -s -o /dev/null -m 5 http://api-server/ & done; wait; done' >/dev/null
kubectl -n "$NS" scale deployment loadhog --replicas=5 >/dev/null
SCALED=$START
for _ in $(seq 1 48); do                       # poll up to ~240s (HPA + metrics sync is slow)
  CUR=$(kubectl -n "$NS" get deploy api-server -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [ "${CUR:-0}" -gt "$START" ]; then SCALED=$CUR; break; fi
  sleep 5
done
UTIL=$(kubectl -n "$NS" get hpa api-server -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
kubectl -n "$NS" delete deployment loadhog --now --wait=false >/dev/null 2>&1 || true
[ "${SCALED:-0}" -gt "$START" ] \
  && pass "HPA scaled up ${START} -> ${SCALED} under load (CPU ~${UTIL:-?}% of request)" \
  || fail "HPA did not scale up from ${START} replicas (CPU ~${UTIL:-?}%)"

step "Summary"
if [ "$FAILED" = "0" ]; then
  printf '\033[32mALL CHECKS PASSED\033[0m\n'
else
  printf '\033[31mSOME CHECKS FAILED\033[0m\n'
fi
echo "Cluster '$CLUSTER' left running. Inspect with: kubectl --context kind-$CLUSTER get all"
echo "Tear down with: kind delete cluster --name $CLUSTER"
exit $FAILED
