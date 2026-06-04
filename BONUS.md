# Bonus answers & testing strategy

## Bonus 1 — Registry unavailable during a node restart or scale-out

A node restart or scale-out triggers an image pull. If the registry is unreachable, new or
restarted pods get stuck in `ImagePullBackOff` — capacity drops or a scale-out fails exactly
when load is rising. Defense in depth, from manifest to infrastructure:

1. **Cache + pin.** `imagePullPolicy: IfNotPresent` and pin the image by **digest**
   (`@sha256:…`). A node that already ran the image reuses cached layers — no pull unless the
   image is genuinely absent. (Done here with `IfNotPresent` + tag; digest is the prod step.)
2. **Registry mirror / pull-through cache.** ECR pull-through cache, Harbor proxy, or a
   containerd `registry.mirrors` entry — pulls are served from an HA local mirror, decoupled
   from the upstream registry's availability.
3. **Pre-warm nodes.** Bake the pinned image into the node AMI / golden image, or run a
   DaemonSet image-warmer that pre-pulls the digest onto every node (including freshly scaled
   ones via bootstrap). New nodes boot with the image already present.
4. **Warm capacity.** cluster-autoscaler warm pools / light over-provisioning so a scale-out
   lands on nodes that already have the image instead of doing a cold pull.
5. **Redundancy.** Replicate the image to a second registry/region with fallback, and keep
   `imagePullSecrets` valid so an `Always` policy still starts pods from cache.

Immediate manifest fix: **digest + `IfNotPresent`**. Infra answer: **mirror + AMI pre-bake +
warm pool**.

## Bonus 2 — How I test that the HA changes actually work

### What runs today
`test/run-test.sh` brings up a kind cluster and asserts, on every push in CI: one-pod-per-zone
spread, Service endpoints (the selector fix), `/health` 200 through the Service, a
**zero-downtime rolling update** (0 failed requests), a **PDB-protected node drain** (≥2 stay
available), and **HPA scale-up under load**. Green e2e is required to merge.

### Environment-tiered strategy
- **Local + dev → kind.** Fast, disposable, free; the *same* suite runs in CI on push. Best
  signal-per-second for catching manifest/logic regressions early. Limitation: kindnet doesn't
  enforce NetworkPolicy and there's no cloud LB / EBS, so kind validates **logic**, not cloud
  behaviour.
- **Staging + prod → a cluster as close to production as possible.** Same Kubernetes version,
  the same *enforcing* CNI as prod (Calico/Cilium), real cloud load balancer, real
  `StorageClass`, real instance types and zone topology. On AWS this is a **dedicated
  test/validation account** — isolated blast radius, EKS configured like prod. The HA + chaos +
  load suite runs there **on merge to `main`** as the promotion gate, before prod.

Promotion flow:
`PR → kind e2e (push) → merge to main → deploy to validation account (prod-like) → HA/chaos/load gates → promote to prod (GitOps)`.

### Chaos / HA validation in the prod-like environment
- Kill pods randomly (Chaos Mesh / kube-monkey) under load — service stays up.
- Cordon an entire zone's nodes (simulated AZ outage) under load (k6/vegeta) — watch error
  rate + p99 latency.
- Drain nodes / cluster upgrade — PDB holds, no request loss.
- Kill PostgreSQL — verify graceful degradation, not a crash loop.
- Rollout **and rollback** under load — both zero-downtime.

## Methodology — TDD (test-driven)
The e2e checks are the **executable spec**. Each requirement starts as a *failing* assertion
("Service has endpoints", "0 failed requests during rollout", "scales under load"); the
manifest is then changed until it goes green. New requirements are added as a new failing check
first, then satisfied. This keeps the manifests honest and the suite is living documentation of
the HA guarantees.
