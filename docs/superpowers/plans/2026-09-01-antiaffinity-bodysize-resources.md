# Chart: Anti-Affinity Defaults, max-body-size, Tiered Resource Defaults — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Spread each vNext component's replicas across nodes by default (anti-affinity), replace the deprecated Dapr body-size annotation with `dapr.io/max-body-size`, and replace the one-size-fits-all resource defaults with measured, tiered per-component defaults.

**Architecture:** All changes live in `charts/vnext` — one new named template in `_helpers.tpl`, an extension of the existing `vnext.daprAnnotations` helper, edits to the four component deployment templates, and `values.yaml` defaults. No app code, no new chart dependencies. Chart version is bumped by CI (`chore: bump chart version … [skip ci]`) — do NOT hand-edit `Chart.yaml`.

**Tech Stack:** Helm v4 (v4.1.1 available locally), Go templates, `helm template`/`helm lint` + python3 assertions for verification.

**Spec:** User request 2026-09-01 (items C, E, B of the intprod latency analysis) + evidence below. Scope EXCLUDES (explicit user decisions): daprd sidecar resource annotations (stays BestEffort — known gap), replica-count changes.

## Evidence (the spec's numbers)

Live bmprod/intprod-vnext-digital-investment measurements (metrics.k8s.io, 2026-08-31): app containers idle at ~1m CPU; orchestrator RSS 440–475Mi, execution 82–100Mi, workers 117–129Mi; daprd 1.5–5.4m CPU / 44–72Mi. Current env values: req 50m/192Mi, limit 1CPU/2Gi for every app container. The observed 40 ms sidecar→app latency correlates with cpu.shares≈51 for the app, CPU limit=1 (disables .NET Server GC; 50 MinThreads on one core), and orchestrator memory request at less than half its steady RSS. Replicas per domain (fixed, out of scope): orchestrator 10, execution 20, inbox 10, outbox 10 → 50 app pods/domain, ~10 vNext domains on bmprod.

Rejected earlier sizing (too expensive at this replica scale): req 500m/1Gi ⇒ 25 cores/domain. Adopted tiered sizing (below) ⇒ ~5.75 cores + ~15Gi requests/domain (today: 2.5 cores / 9.6Gi).

## Global Constraints

- Chart version: never edit `Chart.yaml` `version:` — CI bumps it.
- Additive/override-friendly: every new default must remain overridable per component via existing values keys (`<comp>.affinity`, `<comp>.dapr.*`, `<comp>.resources`).
- Values comment style: keep the file's existing comment-block conventions (English, `# ---` section dividers).
- Tiered resource defaults (exact values):
  - orchestrator: requests `cpu: 200m` / `memory: 512Mi`, limits `cpu: 2000m` / `memory: 2Gi`
  - execution: requests `cpu: 100m` / `memory: 256Mi`, limits `cpu: 2000m` / `memory: 2Gi`
  - worker-inbox and worker-outbox: requests `cpu: 75m` / `memory: 256Mi`, limits `cpu: 1000m` / `memory: 1Gi`
  - `global.resources.default` stays unchanged (fallback for mcp-server/init/db-migrator etc.).
- Anti-affinity default (exact shape, mirrors the redis-sentinel pattern): `preferredDuringSchedulingIgnoredDuringExecution`, weight 100, `topologyKey: kubernetes.io/hostname`, labelSelector = the component's own `vnext.componentSelectorLabels`.
- Body size: new key `global.dapr.maxBodySize: "64Mi"` (+ per-component `dapr.maxBodySize: ""` overrides) emitting `dapr.io/max-body-size`; legacy `global.dapr.httpMaxRequestSize` default becomes `""` but its emission path stays for anyone who sets it explicitly (Dapr deprecated it in 1.13; the platform runs 1.16.12).
- Every task's verification uses `helm template` from `charts/vnext` with default values plus targeted `--set` overrides, asserted with python3 (no eyeballing), and ends with `helm lint charts/vnext` clean.

---

### Task 1: Default pod anti-affinity for the four scalable components

**Files:**
- Modify: `charts/vnext/templates/_helpers.tpl` (append new define)
- Modify: `charts/vnext/templates/orchestrator/deployment.yaml:96-99`
- Modify: `charts/vnext/templates/execution/deployment.yaml:106-109`
- Modify: `charts/vnext/templates/worker-inbox/deployment.yaml:93-96`
- Modify: `charts/vnext/templates/worker-outbox/deployment.yaml:93-96`
- Modify: `charts/vnext/values.yaml` (the four `affinity: {}` comment blocks at ~500, ~759, ~854, ~953)

**Interfaces:**
- Consumes: existing `vnext.componentSelectorLabels` (dict "context" . "component" "<name>").
- Produces: `vnext.defaultPodAntiAffinity` (dict "context" . "component" "<name>") returning a `podAntiAffinity:` YAML block. Task 4's assertions rely on it rendering for all four deployments.

- [ ] **Step 1: Add the helper to `_helpers.tpl`**

```yaml
{{/*
Default preferred pod anti-affinity for a scalable component: spread the component's
replicas across nodes. preferred (not required) so a small cluster can still schedule
more replicas than nodes; weight 100 so the scheduler treats it as the dominant soft
rule. Rendered ONLY when the component's .affinity value is empty — a non-empty
<component>.affinity replaces this wholesale (no merge), same contract as every other
value-driven block in these deployments.
Usage: {{ include "vnext.defaultPodAntiAffinity" (dict "context" . "component" "orchestrator") }}
*/}}
{{- define "vnext.defaultPodAntiAffinity" -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            {{- include "vnext.componentSelectorLabels" (dict "context" .context "component" .component) | nindent 12 }}
{{- end }}
```

- [ ] **Step 2: Wire into the four deployments**

Replace each `{{- with .Values.<comp>.affinity }} … {{- end }}` block with the if/else form. Orchestrator (`templates/orchestrator/deployment.yaml`, current lines 96-99):

```yaml
      {{- if .Values.orchestrator.affinity }}
      affinity:
        {{- toYaml .Values.orchestrator.affinity | nindent 8 }}
      {{- else }}
      affinity:
        {{- include "vnext.defaultPodAntiAffinity" (dict "context" . "component" "orchestrator") | nindent 8 }}
      {{- end }}
```

Execution: same block with `.Values.execution.affinity` / component `"execution"`. Worker-inbox: `$workerInbox.affinity` / component `"worker-inbox"` (note: `$workerInbox`, the template's local, and the context is still `.`). Worker-outbox: `$workerOutbox.affinity` / component `"worker-outbox"`.

- [ ] **Step 3: Update the four values.yaml comments**

At each of the four `affinity: {}` keys, replace the bare key with:

```yaml
  # Pod scheduling affinity. EMPTY ({}) = the chart applies a default preferred
  # podAntiAffinity that spreads this component's replicas across nodes
  # (topologyKey kubernetes.io/hostname, weight 100). Set any non-empty value to
  # REPLACE that default wholesale (no merge).
  affinity: {}
```

- [ ] **Step 4: Verify rendering**

```bash
cd /Users/U0B006/Documents/repos/burgan-tech/vnext-helm-charts
helm template t charts/vnext > /tmp/rendered-default.yaml
python3 - <<'EOF'
import re, sys
doc = open('/tmp/rendered-default.yaml').read()
for comp in ['orchestrator', 'execution', 'worker-inbox', 'worker-outbox']:
    m = re.search(r'kind: Deployment.*?name: t-vnext-' + comp + r'\n.*?(?=\n---)', doc, re.S)
    assert m, f'{comp} deployment not rendered'
    body = m.group(0)
    assert 'podAntiAffinity' in body, f'{comp}: default anti-affinity missing'
    assert 'kubernetes.io/hostname' in body, f'{comp}: topologyKey missing'
    assert f'app.kubernetes.io/component: {comp}' in body, f'{comp}: selector label missing'
print('anti-affinity default OK for all 4')
EOF
helm template t charts/vnext --set-json 'orchestrator.affinity={"nodeAffinity":{}}' | grep -A3 "name: t-vnext-orchestrator$" >/dev/null
helm template t charts/vnext --set-json 'orchestrator.affinity={"nodeAffinity":{}}' > /tmp/rendered-override.yaml
python3 - <<'EOF'
import re
doc = open('/tmp/rendered-override.yaml').read()
m = re.search(r'kind: Deployment.*?name: t-vnext-orchestrator\n.*?(?=\n---)', doc, re.S)
body = m.group(0)
assert 'nodeAffinity' in body and 'podAntiAffinity' not in body, 'override must replace the default wholesale'
print('override replaces default OK')
EOF
```

Adjust the deployment-name regexes to the real rendered names (`helm template` release name `t` → `t-vnext-…`; check the actual `vnext.fullname` output first with `grep "name: t-" /tmp/rendered-default.yaml | head`). Expected: both scripts print OK.

- [ ] **Step 5: Commit**

```bash
git add charts/vnext/templates charts/vnext/values.yaml
git commit -m "feat(scheduling): default preferred pod anti-affinity for orchestrator/execution/workers"
```

---

### Task 2: `dapr.io/max-body-size` replaces the deprecated body-size annotation

**Files:**
- Modify: `charts/vnext/templates/_helpers.tpl` (inside `vnext.daprAnnotations`, the `httpMaxRequestSize` block at ~156-158)
- Modify: `charts/vnext/templates/orchestrator/deployment.yaml:22`, `execution/deployment.yaml:24`, `worker-inbox/deployment.yaml:23`, `worker-outbox/deployment.yaml:23` (the daprAnnotations dict)
- Modify: `charts/vnext/values.yaml` (`global.dapr.httpMaxRequestSize` at ~192; the four per-component `dapr.httpMaxRequestSize` blocks at ~426, ~712, ~807, ~913)

**Interfaces:**
- Produces: values keys `global.dapr.maxBodySize` (default `"64Mi"`) and `<comp>.dapr.maxBodySize` (default `""`); helper dict key `maxBodySize`. Task 4 asserts the rendered annotation.

- [ ] **Step 1: Extend the helper**

In `vnext.daprAnnotations`, replace:

```yaml
{{- if .httpMaxRequestSize }}
dapr.io/http-max-request-size: {{ .httpMaxRequestSize | quote }}
{{- end }}
```

with:

```yaml
{{/* Preferred body-size annotation (Dapr >= 1.13, resource-quantity string e.g. "64Mi").
     The legacy MB-integer annotation below is deprecated but still emitted when a user
     sets httpMaxRequestSize explicitly — e.g. an environment pinned to an old sidecar. */}}
{{- if .maxBodySize }}
dapr.io/max-body-size: {{ .maxBodySize | quote }}
{{- end }}
{{- if .httpMaxRequestSize }}
dapr.io/http-max-request-size: {{ .httpMaxRequestSize | quote }}
{{- end }}
```

- [ ] **Step 2: Thread the new key through the four deployments**

In each deployment's `vnext.daprAnnotations` include, add alongside the existing `"httpMaxRequestSize"` entry (keep that one):

```
"maxBodySize" (coalesce .Values.orchestrator.dapr.maxBodySize .Values.global.dapr.maxBodySize)
```

(execution/worker variants use their own component values: `.Values.execution.dapr.maxBodySize`, `$workerInbox.dapr.maxBodySize`, `$workerOutbox.dapr.maxBodySize`.)

- [ ] **Step 3: values.yaml**

`global.dapr` block (~line 190):

```yaml
    # Maximum request body size for the Dapr sidecar, as a resource quantity
    # (emitted as dapr.io/max-body-size; Dapr >= 1.13). Must agree with the app's
    # Kestrel/gRPC limits and the orchestration-side gRPC channel (64 MB there).
    maxBodySize: "64Mi"
    # LEGACY (Dapr < 1.13): integer MB emitted as dapr.io/http-max-request-size.
    # Deprecated upstream; empty = not emitted. Set only for environments pinned
    # to an old sidecar.
    httpMaxRequestSize: ""
```

Each of the four component `dapr:` blocks gets, next to its existing `httpMaxRequestSize: ""`:

```yaml
    # Override global.dapr.maxBodySize for this component. Empty = use global.
    maxBodySize: ""
```

- [ ] **Step 4: Verify**

```bash
cd /Users/U0B006/Documents/repos/burgan-tech/vnext-helm-charts
helm template t charts/vnext > /tmp/rendered-bodysize.yaml
python3 - <<'EOF'
doc = open('/tmp/rendered-bodysize.yaml').read()
assert doc.count('dapr.io/max-body-size: "64Mi"') == 4, 'expected the annotation on exactly the 4 dapr-enabled app deployments'
assert 'dapr.io/http-max-request-size' not in doc, 'legacy annotation must be gone by default'
print('max-body-size OK')
EOF
helm template t charts/vnext --set global.dapr.httpMaxRequestSize=32 | grep -c 'dapr.io/http-max-request-size: "32"'
# Expected: 4 (legacy path still works when explicitly set)
```

If the count differs because other dapr-enabled pods (db-migrator) also carry annotations, inspect which deployments emit it and adjust the expected count with a comment — the invariant is: every deployment that previously emitted the legacy annotation now emits the new one.

- [ ] **Step 5: Commit**

```bash
git add charts/vnext/templates charts/vnext/values.yaml
git commit -m "feat(dapr): emit dapr.io/max-body-size (64Mi); retire deprecated http-max-request-size default"
```

---

### Task 3: Tiered per-component resource defaults

**Files:**
- Modify: `charts/vnext/values.yaml` — orchestrator `resources:` (~467-475), execution `resources: {}` (~733-734), worker-inbox `resources:` block, worker-outbox `resources:` (~822-830). (Line numbers drift after Tasks 1-2 — locate by the component section headers.)

**Interfaces:**
- Consumes: existing `vnext.resources` helper (component override → global default) — unchanged.
- Produces: the exact tier values from Global Constraints. `global.resources.default` untouched.

- [ ] **Step 1: Replace the four blocks**

Orchestrator:

```yaml
  # Measured (bmprod, 2026-08-31): steady RSS 440-475Mi, idle CPU ~1m. Requests sized to
  # actual steady-state so the scheduler and cpu.shares reflect reality; CPU limit 2 (not 1)
  # keeps .NET Server GC enabled (ProcessorCount >= 2). Limits do not reserve node capacity.
  resources:
    limits:
      cpu: 2000m
      memory: 2Gi
    requests:
      cpu: 200m
      memory: 512Mi
```

Execution:

```yaml
  # Measured: RSS 82-100Mi idle; latency-critical (task invocation path). CPU limit 2 keeps
  # Server GC; memory limit 2Gi leaves headroom for 64Mi payloads in flight.
  resources:
    limits:
      cpu: 2000m
      memory: 2Gi
    requests:
      cpu: 100m
      memory: 256Mi
```

Worker-inbox AND worker-outbox (identical):

```yaml
  # Measured: RSS 117-129Mi; background processing, not client-facing.
  resources:
    limits:
      cpu: 1000m
      memory: 1Gi
    requests:
      cpu: 75m
      memory: 256Mi
```

- [ ] **Step 2: Verify rendering**

```bash
cd /Users/U0B006/Documents/repos/burgan-tech/vnext-helm-charts
helm template t charts/vnext > /tmp/rendered-res.yaml
python3 - <<'EOF'
import re
doc = open('/tmp/rendered-res.yaml').read()
tiers = {'orchestrator': ('200m', '512Mi', '2000m', '2Gi'),
         'execution': ('100m', '256Mi', '2000m', '2Gi'),
         'worker-inbox': ('75m', '256Mi', '1000m', '1Gi'),
         'worker-outbox': ('75m', '256Mi', '1000m', '1Gi')}
for comp, (rc, rm, lc, lm) in tiers.items():
    m = re.search(r'kind: Deployment.*?name: t-vnext-' + comp + r'\n.*?(?=\n---)', doc, re.S)
    body = m.group(0)
    for v in (rc, rm, lc, lm):
        assert v in body, f'{comp}: expected {v}'
print('tiered resources OK')
EOF
```

- [ ] **Step 3: Commit**

```bash
git add charts/vnext/values.yaml
git commit -m "feat(resources): measured tiered defaults per component (orchestrator/execution/workers)"
```

---

### Task 4: Lint, docs, environment-values guidance

**Files:**
- Create: `charts/vnext/docs/RESOURCE_TUNING.md`
- Modify: none beyond the doc.

- [ ] **Step 1: `helm lint` + full-template smoke**

```bash
cd /Users/U0B006/Documents/repos/burgan-tech/vnext-helm-charts
helm lint charts/vnext
helm template t charts/vnext --set global.appDomain=smoke > /dev/null && echo "template OK"
```

Expected: lint 0 failures; template exits 0.

- [ ] **Step 2: Write `charts/vnext/docs/RESOURCE_TUNING.md`**

Content (verbatim skeleton; keep under ~60 lines):

```markdown
# Resource & Scheduling Defaults — Rationale and Environment Overrides

## What the chart defaults are (since chart > 1.0.101)

| Component | requests | limits | Why |
|---|---|---|---|
| orchestrator | 200m / 512Mi | 2 CPU / 2Gi | Steady RSS measured 440-475Mi; CPU limit >= 2 keeps .NET Server GC enabled |
| execution | 100m / 256Mi | 2 CPU / 2Gi | Latency-critical invoke path; headroom for 64Mi payloads |
| worker-inbox / worker-outbox | 75m / 256Mi | 1 CPU / 1Gi | Background processing |

Anti-affinity: each of these components ships a default *preferred* podAntiAffinity
(hostname topology). Override wholesale via `<component>.affinity`.

Body size: `global.dapr.maxBodySize: "64Mi"` emits `dapr.io/max-body-size`. The
deprecated `dapr.io/http-max-request-size` is emitted only if you set
`global.dapr.httpMaxRequestSize` explicitly.

## IMPORTANT: environments override these defaults

An environment values file that sets `global.resources.default` and leaves
`<component>.resources: {}` will IGNORE the tiered defaults above (component-empty
falls back to the ENVIRONMENT's global default). To adopt the tiers in an
environment, either delete the env's `global.resources.default` override or copy the
per-component blocks into the env file.

## Known gap (deliberate, 2026-09-01 decision)

The daprd sidecar carries NO resource requests/limits (BestEffort, cpu.shares=2).
It was the primary suspect in the intprod 40 ms sidecar->app latency finding.
Fixing it needs `dapr.io/sidecar-cpu-request`-family annotations — out of scope
here by explicit decision; revisit if tail latency persists after these changes.
```

- [ ] **Step 3: Commit**

```bash
git add charts/vnext/docs/RESOURCE_TUNING.md
git commit -m "docs: resource tuning rationale, env override guidance, daprd BestEffort known gap"
```

## Self-review notes

- User items C (Task 1), E (Task 2), B (Task 3 + tier table) all covered; daprd sidecar resources explicitly OUT (user decision), documented as known gap (Task 4).
- Chart version bump deliberately absent — CI owns it.
- The env-file trap (env `global.resources.default` masking chart tiers) is called out in Task 4's doc AND must be relayed to the user in the final report with a ready-to-paste env patch.
- Verification is assertion-based on rendered manifests; no cluster access needed.
