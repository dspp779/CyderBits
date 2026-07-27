#!/usr/bin/env python3
"""Validate Cyder CompatDB YAML and encode/inspect bounded CDB v1 files."""

from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path
from typing import Any, Iterable

import yaml


MAGIC = b"CYDRCDB\0"
FORMAT_VERSION = 1
HEADER = struct.Struct("<8sHHIQIIII")
TLV = struct.Struct("<HHI")
HEADER_SIZE = HEADER.size
REQUIRED = 0x0001

RULE_BEGIN = 0x0001
RULE_END = 0x0002
RULE_ID = 0x0010
PRIORITY = 0x0011
ENABLED = 0x0012
MATCH_PATH_SUFFIX = 0x0020
MATCH_FORBIDDEN_ARG = 0x0021
ACTION_APPEND_ARG = 0x0030
ACTION_DLL_OVERRIDE = 0x0031
ACTION_SET_ENV = 0x0032
ACTION_UNSET_ENV = 0x0033
ACTION_GRAPHICS_BACKEND = 0x0034
ACTION_REPLACE_EXECUTABLE = 0x0035
ACTION_WINED3D_RENDERER = 0x0036

MAX_FILE_SIZE = 4 * 1024 * 1024
MAX_SOURCE_SIZE = 1024 * 1024
MAX_RULES = 4096
MAX_RECORDS = 65536
MAX_PAYLOAD = 65536
MAX_STRING = 4096
MAX_MATCHES = 64
MAX_ACTIONS = 64

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
DLL_MODULE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}(?:\.dll)?$")
DLL_LOAD_ORDERS = {
    "native,builtin": "n,b",
    "builtin,native": "b,n",
    "native": "n",
    "builtin": "b",
    "disabled": "",
}
GRAPHICS_BACKENDS = {
    "default": "default",
    "wined3d": "wined3d",
    "dxvk": "dxvk",
    "dxmt": "dxmt",
    "d3dmetal": "d3dmetal",
}
WINED3D_RENDERERS = {
    "auto": "auto",
    "opengl": "gl",
    "gdi": "gdi",
    "vulkan": "vulkan",
}
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,127}$")
FORBIDDEN_ENV_NAMES = {
    "HOME",
    "PATH",
    "WINEPREFIX",
    "WINELOADER",
    "WINESERVER",
    "CYDER_COMPATDB",
    "CYDER_COMPATDB_PATH",
}


class CompatDBError(Exception):
    pass


class StrictSafeLoader(yaml.SafeLoader):
    """SafeLoader which also rejects aliases and duplicate mapping keys."""

    def compose_node(self, parent: Any, index: Any) -> Any:
        if self.check_event(yaml.AliasEvent):
            event = self.peek_event()
            raise CompatDBError(
                f"YAML aliases are not supported (alias {event.anchor!r})"
            )
        return super().compose_node(parent, index)


def _construct_mapping(
    loader: StrictSafeLoader, node: yaml.MappingNode, deep: bool = False
) -> dict[Any, Any]:
    result: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in result
        except TypeError as exc:
            raise CompatDBError("mapping keys must be scalar values") from exc
        if duplicate:
            raise CompatDBError(f"duplicate YAML mapping key: {key!r}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


StrictSafeLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
)


def fail(message: str) -> None:
    raise CompatDBError(message)


def expect_mapping(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{where}: expected mapping")
    if any(not isinstance(key, str) for key in value):
        fail(f"{where}: mapping keys must be strings")
    return value


def expect_keys(
    value: dict[str, Any], required: set[str], allowed: set[str], where: str
) -> None:
    missing = sorted(required - value.keys())
    unknown = sorted(value.keys() - allowed)
    if missing:
        fail(f"{where}: missing keys: {', '.join(missing)}")
    if unknown:
        fail(f"{where}: unknown keys: {', '.join(unknown)}")


def expect_string(value: Any, where: str, maximum: int = MAX_STRING) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{where}: expected nonempty string")
    encoded = value.encode("utf-8")
    if len(encoded) > maximum:
        fail(f"{where}: string exceeds {maximum} UTF-8 bytes")
    if "\0" in value:
        fail(f"{where}: strings may not contain NUL")
    return value


def expect_bool(value: Any, where: str) -> bool:
    if type(value) is not bool:
        fail(f"{where}: expected boolean")
    return value


def expect_int32(value: Any, where: str) -> int:
    if type(value) is not int or not -(2**31) <= value < 2**31:
        fail(f"{where}: expected signed 32-bit integer")
    return value


def ascii_lower(value: str) -> str:
    return "".join(chr(ord(ch) + 32) if "A" <= ch <= "Z" else ch for ch in value)


def normalize_suffix(value: Any, where: str) -> str:
    suffix = expect_string(value, where)
    if "/" in suffix:
        fail(f"{where}: path suffix must use Windows backslashes")
    while "\\\\" in suffix:
        suffix = suffix.replace("\\\\", "\\")
    if not suffix.startswith("\\"):
        fail(f"{where}: path suffix must start with a backslash")
    if any(not 0x20 <= ord(ch) <= 0x7E for ch in suffix):
        fail(f"{where}: CDB v1 path suffix must contain printable ASCII only")
    return ascii_lower(suffix)


def normalize_token(value: Any, where: str) -> str:
    token = expect_string(value, where)
    if any(ch in token for ch in "\r\n"):
        fail(f"{where}: argument token may not contain a newline")
    return token


def option_key(token: str) -> str:
    if token.startswith(("-", "/")):
        return ascii_lower(token.split("=", 1)[0])
    return token


def normalize_dll_module(value: Any, where: str) -> str:
    module = expect_string(value, where, 132)
    if not DLL_MODULE_RE.fullmatch(module):
        fail(f"{where}: expected a DLL basename")
    module = ascii_lower(module)
    if module.endswith(".dll"):
        module = module[:-4]
    return module


def normalize_env_name(value: Any, where: str) -> str:
    name = expect_string(value, where, 128)
    if not ENV_NAME_RE.fullmatch(name):
        fail(f"{where}: expected an ASCII environment variable name")
    canonical = name.upper()
    if (
        canonical in FORBIDDEN_ENV_NAMES
        or canonical.startswith("DYLD_")
        or canonical.startswith("LD_")
        or canonical.startswith("CYDER_")
    ):
        fail(f"{where}: environment variable {name!r} is runtime-controlled")
    return canonical


def normalize_env_value(value: Any, where: str) -> str:
    if not isinstance(value, str):
        fail(f"{where}: expected string")
    encoded = value.encode("utf-8")
    if len(encoded) > MAX_STRING:
        fail(f"{where}: string exceeds {MAX_STRING} UTF-8 bytes")
    if "\0" in value or any(ch in value for ch in "\r\n"):
        fail(f"{where}: environment value may not contain NUL or newlines")
    return value


def normalize_replacement_suffix(value: Any, where: str) -> str:
    suffix = normalize_suffix(value, where)
    components = suffix.split("\\")[1:]
    if (
        not suffix.endswith(".exe")
        or ":" in suffix
        or any(component in ("", ".", "..") for component in components)
    ):
        fail(
            f"{where}: expected a relative Windows suffix ending in .exe "
            "without drive names or dot segments"
        )
    return suffix


def paths_overlap(left: str, right: str) -> bool:
    return left.endswith(right) or right.endswith(left)


def rule_matches(rule: dict[str, Any], fixture: dict[str, Any]) -> bool:
    executable = ascii_lower(fixture["executable"].replace("/", "\\"))
    while "\\\\" in executable:
        executable = executable.replace("\\\\", "\\")
    if not any(executable.endswith(item) for item in rule["path_suffixes"]):
        return False
    argv = fixture["command_line"]
    return not any(token in argv for token in rule["forbidden_args"])


def validate_fixture(value: Any, where: str) -> dict[str, Any]:
    fixture = expect_mapping(value, where)
    keys = {"name", "executable", "command_line"}
    expect_keys(fixture, keys, keys, where)
    name = expect_string(fixture["name"], f"{where}.name", 128)
    executable = expect_string(fixture["executable"], f"{where}.executable")
    command_line = fixture["command_line"]
    if not isinstance(command_line, list) or not command_line:
        fail(f"{where}.command_line: expected nonempty token list")
    tokens = [
        normalize_token(token, f"{where}.command_line[{index}]")
        for index, token in enumerate(command_line)
    ]
    return {"name": name, "executable": executable, "command_line": tokens}


def validate_rule(value: Any, where: str) -> dict[str, Any]:
    source = expect_mapping(value, where)
    keys = {
        "id",
        "description",
        "priority",
        "enabled",
        "stability",
        "applies_to",
        "match",
        "actions",
        "tests",
    }
    expect_keys(source, keys, keys, where)

    rule_id = expect_string(source["id"], f"{where}.id", 128)
    if not ID_RE.fullmatch(rule_id):
        fail(f"{where}.id: must match {ID_RE.pattern}")
    description = expect_string(source["description"], f"{where}.description", 1024)
    priority = expect_int32(source["priority"], f"{where}.priority")
    enabled = expect_bool(source["enabled"], f"{where}.enabled")
    stability = source["stability"]
    if stability not in ("stable", "experimental"):
        fail(f"{where}.stability: expected stable or experimental")

    applies = expect_mapping(source["applies_to"], f"{where}.applies_to")
    expect_keys(
        applies,
        {"platform", "engine_api"},
        {"platform", "engine_api"},
        f"{where}.applies_to",
    )
    if applies["platform"] != "macos" or applies["engine_api"] != 1:
        fail(f"{where}.applies_to: CDB v1 requires platform macos and engine_api 1")

    match = expect_mapping(source["match"], f"{where}.match")
    expect_keys(
        match, {"executable"}, {"executable", "command_line"}, f"{where}.match"
    )
    executable = expect_mapping(match["executable"], f"{where}.match.executable")
    expect_keys(
        executable,
        {"path_suffix"},
        {"path_suffix"},
        f"{where}.match.executable",
    )
    raw_suffixes = executable["path_suffix"]
    if isinstance(raw_suffixes, str):
        raw_suffixes = [raw_suffixes]
    if not isinstance(raw_suffixes, list) or not 1 <= len(raw_suffixes) <= MAX_MATCHES:
        fail(f"{where}.match.executable.path_suffix: expected 1..{MAX_MATCHES} values")
    suffixes = sorted(
        {
            normalize_suffix(item, f"{where}.match.executable.path_suffix[{index}]")
            for index, item in enumerate(raw_suffixes)
        },
        key=lambda item: item.encode("utf-8"),
    )
    if len(suffixes) != len(raw_suffixes):
        fail(f"{where}.match.executable.path_suffix: duplicate normalized suffix")

    forbidden: list[str] = []
    if "command_line" in match:
        command_line = expect_mapping(
            match["command_line"], f"{where}.match.command_line"
        )
        expect_keys(
            command_line,
            {"excludes"},
            {"excludes"},
            f"{where}.match.command_line",
        )
        excludes = command_line["excludes"]
        if not isinstance(excludes, list) or not 1 <= len(excludes) <= MAX_MATCHES:
            fail(f"{where}.match.command_line.excludes: expected 1..{MAX_MATCHES}")
        for index, exclusion in enumerate(excludes):
            item_where = f"{where}.match.command_line.excludes[{index}]"
            item = expect_mapping(exclusion, item_where)
            expect_keys(item, {"token"}, {"token"}, item_where)
            forbidden.append(normalize_token(item["token"], f"{item_where}.token"))
        forbidden = sorted(set(forbidden), key=lambda item: item.encode("utf-8"))
        if len(forbidden) != len(excludes):
            fail(f"{where}.match.command_line.excludes: duplicate token")

    actions = expect_mapping(source["actions"], f"{where}.actions")
    expect_keys(
        actions,
        set(),
        {
            "append_args",
            "dll_overrides",
            "set_env",
            "unset_env",
            "graphics_backend",
            "wined3d_renderer",
            "replace_executable",
        },
        f"{where}.actions",
    )
    if not actions:
        fail(f"{where}.actions: at least one typed action is required")
    args: list[str] = []
    if "append_args" in actions:
        append = expect_mapping(actions["append_args"], f"{where}.actions.append_args")
        expect_keys(
            append,
            {"args", "deduplicate"},
            {"args", "deduplicate"},
            f"{where}.actions.append_args",
        )
        if append["deduplicate"] != "option":
            fail(f"{where}.actions.append_args.deduplicate: CDB v1 requires option")
        raw_args = append["args"]
        if not isinstance(raw_args, list) or not 1 <= len(raw_args) <= MAX_ACTIONS:
            fail(f"{where}.actions.append_args.args: expected 1..{MAX_ACTIONS} values")
        args = [
            normalize_token(item, f"{where}.actions.append_args.args[{index}]")
            for index, item in enumerate(raw_args)
        ]
        if len(set(args)) != len(args):
            fail(f"{where}.actions.append_args.args: duplicate token")
    keys_seen: dict[str, str] = {}
    for token in args:
        key = option_key(token)
        previous = keys_seen.get(key)
        if previous is not None and previous != token:
            fail(f"{where}.actions: conflicting values {previous!r} and {token!r}")
        keys_seen[key] = token

    dll_overrides: dict[str, str] = {}
    if "dll_overrides" in actions:
        raw_overrides = expect_mapping(
            actions["dll_overrides"], f"{where}.actions.dll_overrides"
        )
        if not 1 <= len(raw_overrides) <= MAX_ACTIONS:
            fail(f"{where}.actions.dll_overrides: expected 1..{MAX_ACTIONS} entries")
        for raw_module, raw_order in raw_overrides.items():
            module = normalize_dll_module(
                raw_module, f"{where}.actions.dll_overrides key"
            )
            if module in dll_overrides:
                fail(
                    f"{where}.actions.dll_overrides: duplicate normalized module {module!r}"
                )
            if raw_order not in DLL_LOAD_ORDERS:
                fail(
                    f"{where}.actions.dll_overrides.{raw_module}: "
                    f"expected one of {', '.join(DLL_LOAD_ORDERS)}"
                )
            dll_overrides[module] = DLL_LOAD_ORDERS[raw_order]

    set_env: dict[str, str] = {}
    if "set_env" in actions:
        raw_set_env = expect_mapping(actions["set_env"], f"{where}.actions.set_env")
        if not 1 <= len(raw_set_env) <= MAX_ACTIONS:
            fail(f"{where}.actions.set_env: expected 1..{MAX_ACTIONS} entries")
        for raw_name, raw_value in raw_set_env.items():
            name = normalize_env_name(raw_name, f"{where}.actions.set_env key")
            if name in set_env:
                fail(f"{where}.actions.set_env: duplicate normalized name {name!r}")
            set_env[name] = normalize_env_value(
                raw_value, f"{where}.actions.set_env.{raw_name}"
            )

    unset_env: list[str] = []
    if "unset_env" in actions:
        raw_unset_env = actions["unset_env"]
        if not isinstance(raw_unset_env, list) or not 1 <= len(raw_unset_env) <= MAX_ACTIONS:
            fail(f"{where}.actions.unset_env: expected 1..{MAX_ACTIONS} names")
        unset_env = [
            normalize_env_name(item, f"{where}.actions.unset_env[{index}]")
            for index, item in enumerate(raw_unset_env)
        ]
        if len(set(unset_env)) != len(unset_env):
            fail(f"{where}.actions.unset_env: duplicate normalized name")
        unset_env.sort()
    overlap = set(set_env) & set(unset_env)
    if overlap:
        fail(f"{where}.actions: cannot set and unset {sorted(overlap)[0]!r}")

    graphics_backend = None
    if "graphics_backend" in actions:
        raw_backend = actions["graphics_backend"]
        if raw_backend not in GRAPHICS_BACKENDS:
            fail(
                f"{where}.actions.graphics_backend: expected one of "
                f"{', '.join(GRAPHICS_BACKENDS)}"
            )
        graphics_backend = GRAPHICS_BACKENDS[raw_backend]

    wined3d_renderer = None
    if "wined3d_renderer" in actions:
        raw_renderer = actions["wined3d_renderer"]
        if raw_renderer not in WINED3D_RENDERERS:
            fail(
                f"{where}.actions.wined3d_renderer: expected one of "
                f"{', '.join(WINED3D_RENDERERS)}"
            )
        wined3d_renderer = WINED3D_RENDERERS[raw_renderer]
        if graphics_backend not in (None, "default", "wined3d"):
            fail(
                f"{where}.actions.wined3d_renderer: requires graphics_backend "
                "default/wined3d or no graphics_backend"
            )

    replace_executable = None
    if "replace_executable" in actions:
        replacement = expect_mapping(
            actions["replace_executable"], f"{where}.actions.replace_executable"
        )
        expect_keys(
            replacement,
            {"path_suffix"},
            {"path_suffix"},
            f"{where}.actions.replace_executable",
        )
        replace_executable = normalize_replacement_suffix(
            replacement["path_suffix"],
            f"{where}.actions.replace_executable.path_suffix",
        )

    action_count = (
        len(args)
        + len(dll_overrides)
        + len(set_env)
        + len(unset_env)
        + int(graphics_backend is not None)
        + int(wined3d_renderer is not None)
        + int(replace_executable is not None)
    )
    if action_count > MAX_ACTIONS:
        fail(f"{where}.actions: combined action count exceeds {MAX_ACTIONS}")
    if replace_executable is not None and action_count != 1:
        fail(
            f"{where}.actions.replace_executable: executable replacement must be "
            "the rule's only action; target-process actions belong in a rule "
            "matching the replacement executable"
        )

    tests = expect_mapping(source["tests"], f"{where}.tests")
    expect_keys(tests, {"matches", "excludes"}, {"matches", "excludes"}, f"{where}.tests")
    positives = tests["matches"]
    negatives = tests["excludes"]
    if not isinstance(positives, list) or not positives:
        fail(f"{where}.tests.matches: at least one positive fixture is required")
    if not isinstance(negatives, list):
        fail(f"{where}.tests.excludes: expected list")
    if forbidden and not negatives:
        fail(f"{where}.tests.excludes: exclusion predicates require a negative fixture")

    result = {
        "id": rule_id,
        "description": description,
        "priority": priority,
        "enabled": enabled,
        "stability": stability,
        "path_suffixes": suffixes,
        "forbidden_args": forbidden,
        "append_args": args,
        "dll_overrides": dict(sorted(dll_overrides.items())),
        "set_env": dict(sorted(set_env.items())),
        "unset_env": unset_env,
        "graphics_backend": graphics_backend,
        "wined3d_renderer": wined3d_renderer,
        "replace_executable": replace_executable,
    }
    for index, fixture in enumerate(positives):
        normalized = validate_fixture(fixture, f"{where}.tests.matches[{index}]")
        if not rule_matches(result, normalized):
            fail(
                f"{where}.tests.matches[{index}] ({normalized['name']}): "
                "fixture does not match rule"
            )
    for index, fixture in enumerate(negatives):
        normalized = validate_fixture(fixture, f"{where}.tests.excludes[{index}]")
        if rule_matches(result, normalized):
            fail(
                f"{where}.tests.excludes[{index}] ({normalized['name']}): "
                "fixture unexpectedly matches rule"
            )
    return result


def source_paths(inputs: Iterable[str]) -> list[Path]:
    paths: list[Path] = []
    for raw in inputs:
        path = Path(raw)
        if path.is_dir():
            paths.extend(path.rglob("*.yml"))
            paths.extend(path.rglob("*.yaml"))
        else:
            paths.append(path)
    unique = sorted(set(paths), key=lambda item: str(item))
    if not unique:
        fail("no YAML input files found")
    return unique


def load_rules(inputs: Iterable[str]) -> list[dict[str, Any]]:
    rules: list[dict[str, Any]] = []
    total_size = 0
    for path in source_paths(inputs):
        try:
            data = path.read_bytes()
        except OSError as exc:
            fail(f"{path}: {exc}")
        total_size += len(data)
        if len(data) > MAX_SOURCE_SIZE or total_size > MAX_FILE_SIZE:
            fail(f"{path}: authoring input exceeds size bound")
        try:
            document = yaml.load(data, Loader=StrictSafeLoader)
        except CompatDBError:
            raise
        except yaml.YAMLError as exc:
            fail(f"{path}: malformed YAML: {exc}")
        root = expect_mapping(document, str(path))
        expect_keys(root, {"schema_version", "rules"}, {"schema_version", "rules"}, str(path))
        if root["schema_version"] != 1:
            fail(f"{path}.schema_version: expected 1")
        raw_rules = root["rules"]
        if not isinstance(raw_rules, list):
            fail(f"{path}.rules: expected list")
        if len(rules) + len(raw_rules) > MAX_RULES:
            fail(f"{path}.rules: total rule count exceeds {MAX_RULES}")
        rules.extend(
            validate_rule(item, f"{path}.rules[{index}]")
            for index, item in enumerate(raw_rules)
        )

    ids: set[str] = set()
    for rule in rules:
        if rule["id"] in ids:
            fail(f"duplicate rule id: {rule['id']}")
        ids.add(rule["id"])
    validate_conflicts([rule for rule in rules if rule["enabled"]])
    return rules


def validate_conflicts(rules: list[dict[str, Any]]) -> None:
    for index, left in enumerate(rules):
        left_options = {option_key(token): token for token in left["append_args"]}
        for right in rules[index + 1 :]:
            if left["priority"] != right["priority"]:
                continue
            if not any(
                paths_overlap(a, b)
                for a in left["path_suffixes"]
                for b in right["path_suffixes"]
            ):
                continue
            right_options = {option_key(token): token for token in right["append_args"]}
            for key in sorted(left_options.keys() & right_options.keys()):
                if left_options[key] != right_options[key]:
                    fail(
                        f"same-priority rules {left['id']!r} and {right['id']!r} "
                        f"have conflicting {key!r} append actions"
                    )
            for module in sorted(
                left["dll_overrides"].keys() & right["dll_overrides"].keys()
            ):
                if left["dll_overrides"][module] != right["dll_overrides"][module]:
                    fail(
                        f"same-priority rules {left['id']!r} and {right['id']!r} "
                        f"have conflicting {module!r} DLL override actions"
                    )
            left_env = {
                **left["set_env"],
                **{name: None for name in left["unset_env"]},
            }
            right_env = {
                **right["set_env"],
                **{name: None for name in right["unset_env"]},
            }
            for name in sorted(left_env.keys() & right_env.keys()):
                if left_env[name] != right_env[name]:
                    fail(
                        f"same-priority rules {left['id']!r} and {right['id']!r} "
                        f"have conflicting {name!r} environment actions"
                    )
            for field, label in (
                ("graphics_backend", "graphics backend"),
                ("wined3d_renderer", "WineD3D renderer"),
                ("replace_executable", "executable replacement"),
            ):
                if (
                    left[field] is not None
                    and right[field] is not None
                    and left[field] != right[field]
                ):
                    fail(
                        f"same-priority rules {left['id']!r} and {right['id']!r} "
                        f"have conflicting {label} actions"
                    )


def record(record_type: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        fail(f"record 0x{record_type:04x}: payload exceeds bound")
    return TLV.pack(record_type, REQUIRED, len(payload)) + payload


def encode_string(record_type: int, value: str) -> bytes:
    payload = value.encode("utf-8")
    if not 0 < len(payload) <= MAX_STRING:
        fail(f"record 0x{record_type:04x}: invalid string size")
    return record(record_type, payload)


def encode(rules: list[dict[str, Any]]) -> bytes:
    enabled = sorted(
        (rule for rule in rules if rule["enabled"]),
        key=lambda item: (-item["priority"], item["id"].encode("utf-8")),
    )
    records: list[bytes] = []
    for rule in enabled:
        records.append(record(RULE_BEGIN))
        records.append(encode_string(RULE_ID, rule["id"]))
        records.append(record(PRIORITY, struct.pack("<i", rule["priority"])))
        records.append(record(ENABLED, b"\x01"))
        records.extend(
            encode_string(MATCH_PATH_SUFFIX, suffix)
            for suffix in rule["path_suffixes"]
        )
        records.extend(
            encode_string(MATCH_FORBIDDEN_ARG, token)
            for token in rule["forbidden_args"]
        )
        records.extend(
            encode_string(ACTION_APPEND_ARG, token)
            for token in rule["append_args"]
        )
        records.extend(
            encode_string(ACTION_DLL_OVERRIDE, f"{module}={order}")
            for module, order in rule["dll_overrides"].items()
        )
        records.extend(
            encode_string(ACTION_SET_ENV, f"{name}={value}")
            for name, value in rule["set_env"].items()
        )
        records.extend(
            encode_string(ACTION_UNSET_ENV, name)
            for name in rule["unset_env"]
        )
        if rule["graphics_backend"] is not None:
            records.append(
                encode_string(ACTION_GRAPHICS_BACKEND, rule["graphics_backend"])
            )
        if rule["wined3d_renderer"] is not None:
            records.append(
                encode_string(ACTION_WINED3D_RENDERER, rule["wined3d_renderer"])
            )
        if rule["replace_executable"] is not None:
            records.append(
                encode_string(ACTION_REPLACE_EXECUTABLE, rule["replace_executable"])
            )
        records.append(record(RULE_END))
    if len(records) > MAX_RECORDS:
        fail(f"record count exceeds {MAX_RECORDS}")
    body = b"".join(records)
    file_size = HEADER_SIZE + len(body)
    if file_size > MAX_FILE_SIZE:
        fail(f"CDB size exceeds {MAX_FILE_SIZE}")
    header = HEADER.pack(
        MAGIC,
        FORMAT_VERSION,
        HEADER_SIZE,
        0,
        file_size,
        len(records),
        len(enabled),
        HEADER_SIZE,
        0,
    )
    return header + body


def decode_string(payload: bytes, label: str) -> str:
    if not 0 < len(payload) <= MAX_STRING or b"\0" in payload:
        fail(f"{label}: invalid string payload")
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CompatDBError(f"{label}: invalid UTF-8") from exc


def decode(data: bytes) -> dict[str, Any]:
    if len(data) < HEADER_SIZE or len(data) > MAX_FILE_SIZE:
        fail("CDB file size is outside bounds")
    (
        magic,
        version,
        header_size,
        flags,
        file_size,
        record_count,
        rule_count,
        records_offset,
        reserved,
    ) = HEADER.unpack_from(data)
    if magic != MAGIC:
        fail("invalid CDB magic")
    if version != FORMAT_VERSION:
        fail(f"unsupported CDB format version: {version}")
    if (header_size, flags, records_offset, reserved) != (HEADER_SIZE, 0, HEADER_SIZE, 0):
        fail("unsupported CDB v1 header fields")
    if file_size != len(data):
        fail("declared CDB file size does not match actual size")
    if record_count > MAX_RECORDS or rule_count > MAX_RULES:
        fail("declared CDB counts exceed bounds")

    offset = records_offset
    current: dict[str, Any] | None = None
    rules: list[dict[str, Any]] = []
    observed_records = 0

    def invalidate(message: str) -> None:
        assert current is not None
        current["valid"] = False
        current["errors"].append(message)

    for _ in range(record_count):
        if offset + TLV.size > len(data):
            fail("truncated TLV header")
        record_type, record_flags, payload_size = TLV.unpack_from(data, offset)
        offset += TLV.size
        if payload_size > MAX_PAYLOAD or payload_size > len(data) - offset:
            fail("TLV payload exceeds bounds")
        payload = data[offset : offset + payload_size]
        offset += payload_size
        observed_records += 1

        if record_type == RULE_BEGIN:
            if current is not None or payload or record_flags != REQUIRED:
                fail("invalid or nested RULE_BEGIN")
            current = {
                "id": None,
                "priority": None,
                "enabled": None,
                "path_suffixes": [],
                "forbidden_args": [],
                "append_args": [],
                "dll_overrides": [],
                "set_env": [],
                "unset_env": [],
                "graphics_backend": None,
                "wined3d_renderer": None,
                "replace_executable": None,
                "valid": True,
                "errors": [],
                "unknown_optional": [],
            }
            continue
        if record_type == RULE_END:
            if current is None or payload or record_flags != REQUIRED:
                fail("invalid or unmatched RULE_END")
            if current["id"] is None:
                invalidate("missing RULE_ID")
            if current["priority"] is None:
                invalidate("missing PRIORITY")
            if current["enabled"] is None:
                invalidate("missing ENABLED")
            if not current["path_suffixes"]:
                invalidate("missing MATCH_PATH_SUFFIX")
            action_count = (
                len(current["append_args"])
                + len(current["dll_overrides"])
                + len(current["set_env"])
                + len(current["unset_env"])
                + int(current["graphics_backend"] is not None)
                + int(current["wined3d_renderer"] is not None)
                + int(current["replace_executable"] is not None)
            )
            if not action_count:
                invalidate("missing action")
            if len(current["path_suffixes"]) + len(current["forbidden_args"]) > MAX_MATCHES:
                invalidate("match count exceeds bound")
            if action_count > MAX_ACTIONS:
                invalidate("action count exceeds bound")
            if (
                current["wined3d_renderer"] is not None
                and current["graphics_backend"] not in (None, "default", "wined3d")
            ):
                invalidate("WineD3D renderer requires the WineD3D backend")
            rules.append(current)
            current = None
            continue
        if current is None:
            fail("record outside rule")
        if record_flags & ~REQUIRED:
            invalidate(f"record 0x{record_type:04x} has unknown flags")
            continue
        if record_type not in {
            RULE_ID,
            PRIORITY,
            ENABLED,
            MATCH_PATH_SUFFIX,
            MATCH_FORBIDDEN_ARG,
            ACTION_APPEND_ARG,
            ACTION_DLL_OVERRIDE,
            ACTION_SET_ENV,
            ACTION_UNSET_ENV,
            ACTION_GRAPHICS_BACKEND,
            ACTION_WINED3D_RENDERER,
            ACTION_REPLACE_EXECUTABLE,
        }:
            if record_flags & REQUIRED:
                invalidate(f"unknown required record 0x{record_type:04x}")
            else:
                current["unknown_optional"].append(f"0x{record_type:04x}")
            continue
        if record_flags != REQUIRED:
            invalidate(f"known record 0x{record_type:04x} is not required")
            continue
        try:
            if record_type == RULE_ID:
                if current["id"] is not None:
                    invalidate("duplicate RULE_ID")
                else:
                    current["id"] = decode_string(payload, "RULE_ID")
            elif record_type == PRIORITY:
                if current["priority"] is not None or len(payload) != 4:
                    invalidate("duplicate or malformed PRIORITY")
                else:
                    current["priority"] = struct.unpack("<i", payload)[0]
            elif record_type == ENABLED:
                if current["enabled"] is not None or payload not in (b"\0", b"\1"):
                    invalidate("duplicate or malformed ENABLED")
                else:
                    current["enabled"] = payload == b"\1"
            elif record_type == MATCH_PATH_SUFFIX:
                current["path_suffixes"].append(
                    decode_string(payload, "MATCH_PATH_SUFFIX")
                )
            elif record_type == MATCH_FORBIDDEN_ARG:
                current["forbidden_args"].append(
                    decode_string(payload, "MATCH_FORBIDDEN_ARG")
                )
            elif record_type == ACTION_APPEND_ARG:
                current["append_args"].append(
                    decode_string(payload, "ACTION_APPEND_ARG")
                )
            elif record_type == ACTION_DLL_OVERRIDE:
                value = decode_string(payload, "ACTION_DLL_OVERRIDE")
                if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,127}=(?:n,b|b,n|n|b)?", value):
                    invalidate("malformed ACTION_DLL_OVERRIDE")
                else:
                    current["dll_overrides"].append(value)
            elif record_type == ACTION_SET_ENV:
                value = decode_string(payload, "ACTION_SET_ENV")
                if "=" not in value:
                    invalidate("malformed ACTION_SET_ENV")
                else:
                    name, env_value = value.split("=", 1)
                    try:
                        normalized = normalize_env_name(name, "ACTION_SET_ENV name")
                        normalize_env_value(env_value, "ACTION_SET_ENV value")
                    except CompatDBError as exc:
                        invalidate(str(exc))
                    else:
                        current["set_env"].append(f"{normalized}={env_value}")
            elif record_type == ACTION_UNSET_ENV:
                value = decode_string(payload, "ACTION_UNSET_ENV")
                try:
                    current["unset_env"].append(
                        normalize_env_name(value, "ACTION_UNSET_ENV")
                    )
                except CompatDBError as exc:
                    invalidate(str(exc))
            elif record_type == ACTION_GRAPHICS_BACKEND:
                value = decode_string(payload, "ACTION_GRAPHICS_BACKEND")
                if current["graphics_backend"] is not None or value not in set(GRAPHICS_BACKENDS.values()):
                    invalidate("duplicate or malformed ACTION_GRAPHICS_BACKEND")
                else:
                    current["graphics_backend"] = value
            elif record_type == ACTION_WINED3D_RENDERER:
                value = decode_string(payload, "ACTION_WINED3D_RENDERER")
                if current["wined3d_renderer"] is not None or value not in set(WINED3D_RENDERERS.values()):
                    invalidate("duplicate or malformed ACTION_WINED3D_RENDERER")
                else:
                    current["wined3d_renderer"] = value
            elif record_type == ACTION_REPLACE_EXECUTABLE:
                value = decode_string(payload, "ACTION_REPLACE_EXECUTABLE")
                if current["replace_executable"] is not None:
                    invalidate("duplicate ACTION_REPLACE_EXECUTABLE")
                else:
                    try:
                        value = normalize_replacement_suffix(
                            value, "ACTION_REPLACE_EXECUTABLE"
                        )
                    except CompatDBError as exc:
                        invalidate(str(exc))
                    else:
                        current["replace_executable"] = value
        except CompatDBError as exc:
            invalidate(str(exc))

    if observed_records != record_count or offset != len(data):
        fail("record count or trailing data mismatch")
    if current is not None:
        fail("unterminated rule")
    if len(rules) != rule_count:
        fail("declared rule count does not match rule boundaries")
    observed_ids = [rule["id"] for rule in rules if rule["id"] is not None]
    if len(observed_ids) != len(set(observed_ids)):
        fail("duplicate rule ID in runtime database")
    return {
        "format_version": version,
        "file_size": file_size,
        "record_count": record_count,
        "rule_count": rule_count,
        "rules": rules,
    }


def command_validate(args: argparse.Namespace) -> None:
    rules = load_rules(args.inputs)
    enabled = sum(rule["enabled"] for rule in rules)
    print(f"valid: {len(rules)} authoring rules, {enabled} enabled")


def command_compile(args: argparse.Namespace) -> None:
    rules = load_rules(args.inputs)
    data = encode(rules)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    decoded = decode(data)
    print(
        f"wrote {output}: {decoded['rule_count']} rules, "
        f"{decoded['record_count']} records, {len(data)} bytes"
    )


def command_inspect(args: argparse.Namespace) -> None:
    path = Path(args.cdb)
    try:
        data = path.read_bytes()
    except OSError as exc:
        fail(f"{path}: {exc}")
    result = decode(data)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2))
        return
    print(
        f"CDB v{result['format_version']}: {result['rule_count']} rules, "
        f"{result['record_count']} records, {result['file_size']} bytes"
    )
    for rule in result["rules"]:
        state = "valid" if rule["valid"] else "invalid"
        print(f"- {rule['id'] or '<unknown>'} priority={rule['priority']} {state}")
        for error in rule["errors"]:
            print(f"  error: {error}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)

    validate = subcommands.add_parser("validate", help="validate YAML and fixtures")
    validate.add_argument("inputs", nargs="+", help="YAML files or directories")
    validate.set_defaults(func=command_validate)

    compile_command = subcommands.add_parser("compile", help="compile YAML to CDB v1")
    compile_command.add_argument("inputs", nargs="+", help="YAML files or directories")
    compile_command.add_argument("-o", "--output", required=True)
    compile_command.set_defaults(func=command_compile)

    inspect = subcommands.add_parser("inspect", help="decode and validate CDB v1")
    inspect.add_argument("cdb")
    inspect.add_argument("--json", action="store_true")
    inspect.set_defaults(func=command_inspect)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.func(args)
    except CompatDBError as exc:
        print(f"cyder-compatdb: error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
