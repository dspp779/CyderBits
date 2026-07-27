#!/usr/bin/env python3
"""Minimal model of the CompatDB graphics-backend environment handoff."""

from __future__ import annotations


VALID_BACKENDS = {"wined3d", "dxvk", "dxmt", "d3dmetal"}


def activate_backend(environment: dict[str, str], rule_backend: str | None) -> str | None:
    """Preserve the App selection across a CompatDB child-environment rule."""
    forced = environment.get("CYDER_GRAPHICS_BACKEND")
    if rule_backend is not None:
        environment["CYDER_GRAPHICS_BACKEND"] = rule_backend

    if forced in VALID_BACKENDS:
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
    print(activate_backend(environment, rule_backend) or "")
