#!/usr/bin/env python3
"""Minimal model of the CompatDB graphics-backend environment handoff."""

from __future__ import annotations


VALID_BACKENDS = {"wined3d", "dxvk", "dxmt", "d3dmetal"}


def forced_backend(environment: dict[str, str]) -> str | None:
    forced = environment.get("CYDER_GRAPHICS_BACKEND")
    return forced if forced in VALID_BACKENDS else None


def should_apply_rule_graphics(environment: dict[str, str]) -> bool:
    """App force must skip CompatDB graphics_backend (avoid DLL/path stacking)."""
    return forced_backend(environment) is None


def activate_backend(environment: dict[str, str], rule_backend: str | None) -> str | None:
    """Preserve the App selection across a CompatDB child-environment rule."""
    forced = forced_backend(environment)
    if rule_backend is not None and should_apply_rule_graphics(environment):
        environment["CYDER_GRAPHICS_BACKEND"] = rule_backend

    if forced is not None:
        return forced
    selected = environment.get("CYDER_GRAPHICS_BACKEND")
    if selected in VALID_BACKENDS:
        return selected
    return None


if __name__ == "__main__":
    import json
    import sys

    environment = json.loads(sys.argv[1])
    rule_backend = sys.argv[2] if len(sys.argv) > 2 else None
    if len(sys.argv) > 3 and sys.argv[3] == "--skip-check":
        print("1" if should_apply_rule_graphics(environment) else "0")
    else:
        print(activate_backend(environment, rule_backend) or "")
