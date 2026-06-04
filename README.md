# Take-Home Challenge — Senior DevOps Engineer

## Scenario

You've inherited a Kubernetes deployment for a web API service running in production.
The service handles HTTP requests and connects to a PostgreSQL database
at `postgres.default.svc.cluster.local:5432`.

The cluster runs on AWS across **three availability zones**: `zone-a`, `zone-b`, `zone-c`.

Your task is to review the provided manifests, identify issues, and improve them for
production readiness, high availability, and operational excellence.

## Files provided

- `deployment.yaml` — the main application deployment
- `service.yaml` — the Kubernetes Service
- `configmap.yaml` — application configuration
- `hpa.yaml` — Horizontal Pod Autoscaler
- `vpa.yaml` — Vertical Pod Autoscaler

## Task

1. Review all manifests and identify all issues — correctness, security, reliability,
   and operational concerns.
2. Modify or add to the manifests to make the service production-grade.
3. Write a `CHANGES.md` describing:
   - What you changed and why
   - Any issues you spotted beyond the stated scope
   - Trade-offs you considered
   - What you would add or do differently in a real production rollout

## What we're looking for

- The service should tolerate pod, node, and zone failures without downtime
- Deployments should be safe to roll out and roll back without service interruption
- Configuration should follow security best practices
- The service should scale predictably under load
- External dependencies (image registry, database) should be treated as unreliable

## Bonus (not required)

- How would you handle the case where the external image registry becomes unavailable
  during a node restart or scale-out event?
- How would you test that your HA changes actually work?

You may answer the bonus questions in writing (in your `CHANGES.md`) or verbally during
the follow-up interview — either is fine.

## Time expectation

2–3 hours. Depth of reasoning matters more than completeness.

## Submission

Return a zip or git repo containing all modified/added files plus your `CHANGES.md`.
