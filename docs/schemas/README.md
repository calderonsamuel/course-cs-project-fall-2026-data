# Data schemas

For the project-level overview and what the agents are for, see [../project-status.md](../project-status.md).

This folder documents every file the pipeline reads or writes, layer by layer, and the rules each file must satisfy. `scripts/validate_schemas.R` checks those rules against the files on disk and writes the result to [validation-report.md](validation-report.md).

The documents are the reference. If a script and a document disagree, one of them is wrong and the validator should report it.

## Layers

| # | Layer | Document | Produced by | Files |
|---|---|---|---|---|
| 1 | Raw sources | [01-raw-sources.md](01-raw-sources.md) | `download_*.R` | `data/raw/` |
| 2 | Provision units | [02-provisions.md](02-provisions.md) | `parse_provisions.R` | `data/processed/provisions/<CELEX>.jsonl` |
| 3 | Version alignment | [03-alignment.md](03-alignment.md) | `align_versions.R` | `data/processed/alignment/<OLD>__<NEW>.jsonl`, `..._containers.csv` |
| 4 | Obligations | [04-obligations.md](04-obligations.md) | `extract_obligations.R` | `data/processed/obligations/<CELEX>.jsonl` |
| 5 | Organization graph | [05-org-graph.md](05-org-graph.md) | `build_org_graph.R` | `data/processed/org_graph/nodes.jsonl`, `edges.jsonl` |
| – | Reference tables | [06-reference-tables.md](06-reference-tables.md) | edited by hand | `data/reference/*.csv` |

Data flows down the table: layer 2 reads layer 1, layer 3 reads layer 2, and so on. The organization graph reads the raw register and budget files plus the reference tables.

```
raw EUR-Lex ─► provisions ─► alignment ─► obligations ─┐
                    └──────────────────────► obligations ├─► agents (not built)
raw register + raw CBS + reference tables ─► org graph ─┘
```

## Conventions

**File formats.**
- JSON Lines (`.jsonl`): one JSON object per line, UTF-8. All objects in a file share the same keys; a missing value is written as `null`, never left out.
- CSV: UTF-8, comma-separated, header row, values with commas quoted. Codes that look like numbers (task fields such as `0.1` and `0.10`) are text and must be read as text.

**Types used in the field tables.**

| Type | Meaning |
|---|---|
| string | JSON string |
| integer | whole number |
| number | number, possibly fractional |
| boolean | `true` / `false` |
| date | string `YYYY-MM-DD` |
| enum | string from a fixed list, given in the table |
| id | string matching the pattern given in the table |
| list | string of values separated by `;` (kept flat so CSV and JSONL stay simple) |

**Required.** "yes" means the value is never `null` and never an empty string. "yes, may be empty" means never `null`, but an empty string is allowed. "no" means `null` is allowed; the table says when it is expected.

**Identifiers.**

| Id | Pattern | Example |
|---|---|---|
| CELEX | `^[0-9]{5}[A-Z]{1,2}[0-9]{4}$` | `32024R1689`, `52021PC0206` |
| Provision unit | `<CELEX>:<path>` | `32024R1689:art26.par9` |
| Obligation | `<unit_id>#<n>` | `32024R1689:art26.par9#1` |
| Municipality | `^GM[0-9]{4}$` (CBS code) | `GM0518` |
| System | `sys:<algorithm_id>` | `sys:44851255` |
| Department | `<GM code>:dept:<slug>` | `GM0518:dept:stadsbeheer` |
| Supplier | `sup:<slug>`, or `<GM code>:sup:in-house` | `sup:centric` |
| Task field | `<GM code>:tf:<BBV code>` | `GM0363:tf:6.3` |

**Provenance.** Every processed file can be traced to its source: provision units carry `source_file` and `source_ref`; obligations carry the unit id and character offsets; every graph node and edge carries `source`, `source_ref` and `confidence`. Raw downloads have a manifest with URL, time and MD5 checksum.

## Validating

From the project root:

```
Rscript scripts/validate_schemas.R
```

The script prints a summary and writes [validation-report.md](validation-report.md). Each check is `PASS`, `WARN` (allowed but worth a look) or `FAIL` (breaks a rule in these documents). It exits with status 1 if any check fails.

Checks come in five kinds:

1. **Structure**: the file exists and parses, every documented field is present, and no undocumented field appears.
2. **Values**: types, required fields, allowed values and id patterns.
3. **Keys**: ids are unique.
4. **References**: every id that points to another record finds it (parent units, aligned units, obligation units, graph edge endpoints, task-field codes).
5. **Content rules**: rules specific to a layer, such as "an obligation's span is the exact text at its offsets", "an added unit has no old id", or "manifest checksums match the files".
