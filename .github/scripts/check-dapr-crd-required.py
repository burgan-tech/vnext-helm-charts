#!/usr/bin/env python3
"""Check every rendered dapr.io object against the `required` lists in the vendored CRDs.

helm lint / helm template never validate against CRD schemas, so a missing required field
only surfaces at apply time, e.g.
  Resiliency.dapr.io "..." is invalid: spec.targets: Required value
  Configuration.dapr.io "appconfig" is invalid: spec.nameResolution.version: Required value

Usage: check-dapr-crd-required.py <crd-dir> <rendered-manifests.yaml>
"""
import glob
import sys

import yaml

crd_dir, rendered = sys.argv[1], sys.argv[2]

schemas = {}
for f in glob.glob(f"{crd_dir}/*.yaml"):
    for d in yaml.safe_load_all(open(f)):
        if d and d.get("kind") == "CustomResourceDefinition":
            group, kind = d["spec"]["group"], d["spec"]["names"]["kind"]
            for v in d["spec"]["versions"]:
                schemas[(f"{group}/{v['name']}", kind)] = v["schema"]["openAPIV3Schema"]


def walk(node, schema, path, errs):
    if not isinstance(schema, dict):
        return
    if isinstance(node, dict):
        for r in schema.get("required", []):
            if r not in node:
                errs.append(f"{path}.{r}: Required value")
        props = schema.get("properties", {})
        for key, val in node.items():
            if key in props:
                walk(val, props[key], f"{path}.{key}", errs)
            elif isinstance(schema.get("additionalProperties"), dict):
                walk(val, schema["additionalProperties"], f"{path}.{key}", errs)
    elif isinstance(node, list) and "items" in schema:
        for i, item in enumerate(node):
            walk(item, schema["items"], f"{path}[{i}]", errs)


bad = checked = 0
for d in yaml.safe_load_all(open(rendered)):
    if not d or (d.get("apiVersion"), d.get("kind")) not in schemas:
        continue
    checked += 1
    errs = []
    walk(d, schemas[(d["apiVersion"], d["kind"])], "", errs)
    for e in errs:
        bad += 1
        print(f"::error::{d['kind']} {d['metadata']['name']}: {e.lstrip('.')}")

print(f"checked {checked} dapr.io objects against vendored CRDs, {bad} missing required field(s)")
sys.exit(1 if bad else 0)
