# CHANGES

Production-hardening of the inherited `api-server` manifests. Bonus answers + test strategy: see [BONUS.md](BONUS.md).

## Blockers
- service: selector `app: api` → `app: api-server` (Service had zero endpoints).
- deployment: rollout `maxUnavailable 100% / maxSurge 0` → `0 / 1` (no downtime on release).

## Security
- secret: DB creds out of git — injected from a CI secret into a k8s Secret (prod: External Secrets / Vault); hardcoded IP → cluster DNS.
- deployment: non-root (uid 1000), drop ALL caps, no privilege escalation, `readOnlyRootFilesystem`, seccomp `RuntimeDefault`.
- serviceaccount: dedicated SA, `automountServiceAccountToken: false`.
- configmap: `LOG_LEVEL: debug` → `info`.

## HA / reliability
- deployment: 1 → 3 replicas; zone `topologySpreadConstraints`; startup/readiness/liveness probes; CPU/mem requests+limits; graceful shutdown (preStop + grace period).
- pdb: `minAvailable: 2`.
- networkpolicy: default-deny; ingress 8080; egress scoped to kube-dns + postgres:5432.

## Autoscaling
- hpa: target `95%` → `70%`; `minReplicas` 1 → 3; scale-down stabilization.
- vpa: `Auto` → `Off` (recommend-only — stops fighting HPA on CPU) + min/max bounds.

## Image
- deployment: pinned tag + `imagePullPolicy: IfNotPresent` (deterministic rollback, survives registry outage).

## Tested
- kind e2e in CI on push (5 workers / 3 zones): zone spread, endpoints, `/health`, zero-downtime rollout, PDB drain, HPA scale-up. Built test-first (TDD) — details in [BONUS.md](BONUS.md).
