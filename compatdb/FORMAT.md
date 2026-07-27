# Cyder CompatDB CDB v1

This document defines the binary format consumed by the Cyder Wine runtime.
YAML is the authoring format only. The runtime never parses YAML.

All offsets and sizes are byte counts. All integers are unsigned little-endian
unless explicitly described otherwise. A conforming writer emits records in the
canonical order described below. A reader must apply every bound before
allocating memory or advancing an offset.

## Global bounds

| Item | v1 maximum |
|---|---:|
| File size | 4 MiB |
| Rules | 4,096 |
| Records | 65,536 |
| Record payload | 65,536 bytes |
| UTF-8 string payload | 4,096 bytes |
| Match records per rule | 64 |
| Action records per rule | 64 |

Writers may enforce smaller limits. Files exceeding any runtime limit are
invalid and must be ignored as a whole.

## File header

The fixed header is 40 bytes:

| Offset | Size | Field | Value |
|---:|---:|---|---|
| 0 | 8 | `magic` | ASCII `CYDRCDB` followed by NUL |
| 8 | 2 | `format_version` | `1` |
| 10 | 2 | `header_size` | `40` |
| 12 | 4 | `flags` | `0` in v1 |
| 16 | 8 | `file_size` | Exact size of the complete file |
| 24 | 4 | `record_count` | Number of TLV records after the header |
| 28 | 4 | `rule_count` | Number of `RULE_BEGIN`/`RULE_END` pairs |
| 32 | 4 | `records_offset` | `40` in v1 |
| 36 | 4 | `reserved` | Must be zero |

A reader must reject the complete database when:

- the magic, version, header size, flags, records offset, or reserved value is
  unsupported;
- `file_size` differs from the actual file size;
- declared counts exceed global bounds;
- a size or offset addition overflows;
- any record extends beyond `file_size`;
- trailing bytes remain after exactly `record_count` records;
- rule boundaries or the observed rule count are invalid.

There is no implicit alignment or padding in v1.

## TLV record header

Every record begins with this 8-byte header:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 2 | `type` |
| 2 | 2 | `flags` |
| 4 | 4 | `payload_size` |

The record occupies exactly `8 + payload_size` bytes. Payloads immediately
follow their header; the next record immediately follows the payload.

### Record flags

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `REQUIRED` | A reader must understand this record to apply its rule |
| 1–15 | — | Reserved; writers set zero |

Unknown flag bits make the containing rule invalid. Unknown optional record
types (`REQUIRED` clear) are skipped using `payload_size`. Unknown required
record types invalidate only the containing rule. Parsing continues at the next
record and the invalid rule produces no actions.

An unknown record outside a rule invalidates the complete database, regardless
of flags. The v1 writer does not emit records outside rules.

## Rule structure

Rules are flat, non-overlapping sequences:

```text
RULE_BEGIN
RULE_ID
PRIORITY
ENABLED
[match records...]
[action records...]
RULE_END
```

Nested rules, unmatched boundaries, or records outside a rule invalidate the
complete database. Duplicate singleton records invalidate only their rule.
Every valid enabled rule must contain:

- exactly one `RULE_ID`;
- exactly one `PRIORITY`;
- exactly one `ENABLED`;
- at least one match record;
- at least one action record.

Disabled authoring rules are not emitted by the v1 compiler. `ENABLED` is kept
in the format so a future database overlay can disable a lower-layer rule
without changing the rule representation.

Strings are length-delimited UTF-8 with no NUL terminator. They must be nonempty,
well-formed UTF-8, contain no U+0000, and not exceed the string bound.
`MATCH_PATH_SUFFIX` is further restricted in v1 to printable ASCII bytes
`0x20..0x7e`, begins with a backslash, uses Windows backslashes, and is
ASCII-lowercased by the compiler. This deliberately excludes Unicode paths until
the compiler and runtime share an explicit Windows Unicode case-folding
implementation. Argument tokens remain UTF-8 and preserve case.

Rule IDs are globally unique. Duplicate `RULE_ID` values are a structural
ambiguity and invalidate the complete database, even if one of the duplicate
rules would otherwise be semantically invalid.

## v1 record types

All known v1 records set `REQUIRED`.

| Type | Name | Payload | Cardinality |
|---:|---|---|---|
| `0x0001` | `RULE_BEGIN` | empty | one per rule |
| `0x0002` | `RULE_END` | empty | one per rule |
| `0x0010` | `RULE_ID` | UTF-8 string | exactly one |
| `0x0011` | `PRIORITY` | signed 32-bit little-endian | exactly one |
| `0x0012` | `ENABLED` | one byte: `0` or `1` | exactly one |
| `0x0020` | `MATCH_PATH_SUFFIX` | normalized UTF-8 string | one or more in v1 |
| `0x0021` | `MATCH_FORBIDDEN_ARG` | UTF-8 argument token | zero or more |
| `0x0030` | `ACTION_APPEND_ARG` | UTF-8 argument token | zero or more |
| `0x0031` | `ACTION_DLL_OVERRIDE` | Canonical ASCII `module=order` | zero or more |
| `0x0032` | `ACTION_SET_ENV` | Canonical ASCII name, `=`, UTF-8 value | zero or more |
| `0x0033` | `ACTION_UNSET_ENV` | Canonical ASCII name | zero or more |
| `0x0034` | `ACTION_GRAPHICS_BACKEND` | `default`, `wined3d`, `dxvk`, `dxmt`, or `d3dmetal` | zero or one |
| `0x0035` | `ACTION_REPLACE_EXECUTABLE` | normalized path suffix | zero or one |
| `0x0036` | `ACTION_WINED3D_RENDERER` | `auto`, `gl`, `gdi`, or `vulkan` | zero or one |

`PRIORITY` is the only signed field in v1 and uses two's-complement signed
32-bit little-endian representation.

For `ACTION_DLL_OVERRIDE`, `module` is an ASCII Wine module name normalized to
lowercase without a trailing `.dll`. `order` is one of `n,b`, `b,n`, `n`, `b`,
or the empty string (disabled). The compiler accepts the corresponding YAML
spellings `native,builtin`, `builtin,native`, `native`, `builtin`, and
`disabled`.

Multiple `MATCH_PATH_SUFFIX` records in one rule are OR alternatives. Every
other distinct predicate category is ANDed with the path predicate. Multiple
forbidden tokens mean none may be present. Append actions are applied in record
order. Every enabled rule has at least one action across the supported action
record types.

`MATCH_FORBIDDEN_ARG` compares a parsed Windows command-line token exactly,
case-sensitively. `ACTION_APPEND_ARG` is a complete token, not a command-line
fragment; the runtime owns Windows quoting.

Before appending, the runtime deduplicates against both the original parsed
command line and earlier applied actions. For a token beginning with `-` or `/`,
its option key is the portion through but excluding the first `=` (or the full
token when there is no `=`), compared ASCII-case-insensitively. Other tokens use
the complete token and a case-sensitive comparison. If an option key is already
present, the action is skipped; v1 never silently replaces an author-supplied
value.

`ACTION_DLL_OVERRIDE` modifies only the matched process's in-memory Wine DLL
load-order table. It does not write the bottle Registry and does not install a
DLL. The payload uses an ASCII-lowercase module basename without `.dll`, an
equals sign, and one of these canonical orders:

| Payload | Meaning |
|---|---|
| `ddraw=n,b` | Native first, then Wine builtin |
| `ddraw=b,n` | Wine builtin first, then native |
| `ddraw=n` | Native only |
| `ddraw=b` | Wine builtin only |
| `ddraw=` | Disable the module |

The authoring YAML uses the expanded values `native,builtin`,
`builtin,native`, `native`, `builtin`, and `disabled`. The compiler rejects
paths, wildcards, duplicate normalized module names, unsupported order tokens,
and same-priority conflicting overrides. Provisioning the corresponding native
DLL and its assets belongs to the game Recipe layer.

`ACTION_SET_ENV` and `ACTION_UNSET_ENV` rebuild only the matched child
process's Windows environment block. Names are ASCII-case-insensitive and
canonicalized to uppercase. Host/runtime control names (`PATH`, `HOME`,
`WINEPREFIX`, `WINELOADER`, `WINESERVER`, `CYDER_*`, `DYLD_*`, and `LD_*`) are
rejected. Higher-priority rules win per environment name; environment values
are never written to the trace log.

`ACTION_GRAPHICS_BACKEND` selects the process-local Direct3D translation stack.
An omitted action means normal default selection. An explicit `default` also
blocks lower-priority backend rules and resolves to the engine's safe default,
currently WineD3D. `wined3d` uses Wine's builtin Direct3D modules. `dxvk`, `dxmt`, and `d3dmetal`
select their engine-owned DLL directory and install load-order overrides only
for modules actually present for the process architecture. DXVK is a native
Windows DLL payload, so Cyder provisions it into the bottle during bootstrap
and applies `native,builtin` only to matched processes. The other stacks use
Wine-compatible builtin payloads.
Backend payloads are discovered below the engine root supplied by
`CYDER_GRAPHICS_BACKENDS_ROOT`:

| Backend | Engine payload |
|---|---|
| `dxvk` | `lib/dxvk/<machine>-windows/*.dll` plus a bundled MoltenVK |
| `dxmt` | `lib/dxmt/<machine>-windows/*.dll` plus `x86_64-unix/winemetal.so` |
| `d3dmetal` | `lib64/apple_gptk/wine/<machine>-windows/*.dll`, `libd3dshared.dylib`, and `D3DMetal.framework` |

If the requested backend has no usable module for the current process
architecture, the runtime reports the missing capability and falls back to
WineD3D. It never searches another installed application such as CrossOver.
The selected effective stack is exposed as `CX_ACTIVE_GRAPHICS_BACKEND`.

`ACTION_WINED3D_RENDERER` is a separate lower-level choice. It sets the private
process selector `CYDER_WINED3D_RENDERER`, which Cyder's wined3d patch consumes
after normal Registry and `WINE_D3D_CONFIG` processing. YAML `opengl`, `gdi`,
and `vulkan` compile to `gl`, `gdi`, and `vulkan`; `auto` leaves WineD3D's
normal selection unchanged. This action may be used alone or with
`graphics_backend: wined3d`, but not with another translation stack.

`ACTION_REPLACE_EXECUTABLE` replaces the longest matched source suffix with its
payload, then updates the image path, process parameters, and command-line
argv[0] before Wine opens the PE image. It is exclusive: it must be the only
action in its rule. Actions intended for the replacement process belong in a
separate rule matching the replacement executable. This prevents recursive or
ambiguous source/target action inheritance.

## Canonical writer order

For deterministic output, the compiler:

1. excludes disabled rules;
2. sorts rules by descending `priority`, then bytewise UTF-8 `id`;
3. emits singleton records in the structure order above;
4. sorts path alternatives bytewise after normalization;
5. sorts and deduplicates forbidden tokens bytewise;
6. preserves author-declared append argument order and rejects duplicates;
7. emits DLL overrides sorted by normalized module basename;
8. emits environment actions sorted by normalized name, followed by typed
   graphics-backend, WineD3D-renderer, and executable actions;
9. emits no optional, padding, or unknown records.

Rule IDs must be globally unique across all authoring inputs, including disabled
rules.

## Failure semantics

Header or structural failure, including duplicate rule IDs, invalidates the
complete database. A semantic failure contained within well-formed rule
boundaries invalidates only that rule. An invalid rule never partially applies
actions.

The process-creation hook is fail-open: a missing or invalid database, an
invalid rule, an unsupported required record, or allocation failure must leave
the original image path, command line, and environment unchanged.

## Evolution

Compatible additions use new optional record types. A record whose semantics
are necessary for correctness sets `REQUIRED`, allowing older readers to skip
the rule safely. Incompatible header or structural changes require a new
`format_version`.

Signature and content-addressing metadata are outside the CDB v1 byte stream.
The launcher selects and verifies the immutable file before setting
`CYDER_COMPATDB_PATH`; the runtime still validates all bounds independently.
