# Layer 5: organization graph

Script: `build_org_graph.R`. Files: `data/processed/org_graph/nodes.jsonl`, `edges.jsonl`. Design rationale: [../org-graph-schema.md](../org-graph-schema.md). This page is the field-level reference.

Nodes of different types share one file. Each row has the common fields plus the fields of its type; fields of other types are absent (not `null`) because each type is written as its own block.

## Common node fields

| Field | Type | Required | Content |
|---|---|---|---|
| `id` | id | yes | Unique across all nodes; pattern per type below |
| `type` | enum | yes | `municipality`, `department`, `system`, `supplier`, `taskfield` |
| `source` | enum | yes | `register_current`, `register_history`, `cbs_iv3`, `supplier_alias`, `supplier_rule` |
| `source_ref` | string | yes | Record id in the source: `algorithm_id`, CBS key, … |
| `confidence` | enum | yes | `high`, `medium`, `low`, `unknown` |

## Node types

### municipality — id `^GM[0-9]{4}$`

| Field | Type | Required | Content |
|---|---|---|---|
| `name` | string | yes | Amsterdam, Den Haag, Terneuzen |
| `register_org_id` | string | yes | `org_id` in the algorithm register |

### department — id `^GM[0-9]{4}:dept:[a-z0-9-]+$`

| Field | Type | Required | Content |
|---|---|---|---|
| `municipality` | id | yes | Owning municipality |
| `name` | string | yes | Department name from the register history |

### system — id `^sys:[0-9]+$`

| Field | Type | Required | Content |
|---|---|---|---|
| `municipality` | id | yes | Operating municipality |
| `name` | string | yes | |
| `description_short` | string | yes | |
| `goal` | string | yes | |
| `status` | enum | yes | `In gebruik`, `In ontwikkeling`, `Buiten gebruik` |
| `begin_date`, `end_date` | string | no | `YYYY-MM` |
| `self_category` | enum | yes | `Hoog-risico AI-systeem`, `Impactvolle algoritmes`, `Overige algoritmes` |
| `themes` | string | no | Register themes, comma-separated as in the source |
| `has_dpia`, `has_iama` | boolean | yes | Assessment named in the register |
| `assessments_raw` | string | no | Register `impacttoetsen` |
| `has_human_oversight_text` | boolean | yes | `human_intervention` is filled |
| `methods_and_models`, `human_intervention`, `risks`, `source_data`, `lawful_basis` | string | no | Register text, kept whole |
| `provider_raw` | string | no | Register `provider` |
| `publication_dt` | string | yes | Timestamp of the register version used |
| `aiact_class`, `aiact_role` | string | no | Reserved for agents; `null` until step 4 |

### supplier — id `^sup:[a-z0-9-]+$` or `^GM[0-9]{4}:sup:in-house$`

| Field | Type | Required | Content |
|---|---|---|---|
| `name` | string | yes | Canonical name, or `In-house` |
| `in_house` | boolean | yes | True for the in-house node of a municipality |
| `n_municipalities` | integer | yes | Number of the three municipalities using the supplier, ≥ 1 |

### taskfield — id `^GM[0-9]{4}:tf:[0-9]\.[0-9]+$`

| Field | Type | Required | Content |
|---|---|---|---|
| `municipality` | id | yes | |
| `code` | string | yes | BBV task-field code, `0.1`–`8.3`; key in `dim_taakveld.csv` |
| `title` | string | yes | CBS title |
| `is_overhead` | boolean | yes | True for code `0.4` |
| `budget_2025_keur`, `actuals_2025_keur` | integer | yes | Expenses in thousand euro: all `L` categories except `L7.1` (transfers to reserves), second release where present |
| `budget_personnel_keur`, `actuals_personnel_keur` | integer | yes | Categories `L1.1` + `L3.5.1` |
| `budget_goods_services_keur`, `actuals_goods_services_keur` | integer | yes | Category `L3.8` |

Amounts may be negative (corrections in the municipality's accounts).

## Edge fields

| Field | Type | Required | Content |
|---|---|---|---|
| `from`, `to` | id | yes | Node ids |
| `type` | enum | yes | See below |
| `source` | enum | yes | `register_current`, `register_history`, `cbs_iv3`, `fixed`, `keyword_rule`, `theme_map`, `supplier_alias`, `supplier_rule` |
| `source_ref` | string | yes | What produced the edge: record id, keyword pattern, theme |
| `confidence` | enum | yes | `high`, `medium`, `low`, `unknown` |
| `note` | string | `runs` only | Why confidence is lower |
| `budget_2025_keur` | integer | `spends_on` only | Copy of the task field's budget |

## Edge types

| Type | From → to | Source | Multiplicity |
|---|---|---|---|
| `operates` | municipality → system | `register_current` | exactly one per system |
| `has_department` | municipality → department | `register_history` | exactly one per department |
| `runs` | department → system | `register_history` | at most one per system |
| `supplied_by` | system → supplier | `supplier_alias` or `supplier_rule` | zero or more per system |
| `funded_from` | system → taskfield | `keyword_rule` or `theme_map` | zero or more per system |
| `spends_on` | municipality → taskfield | `cbs_iv3` | exactly one per task field |
| `overhead_of` | taskfield → municipality | `fixed` | exactly one per municipality, from its `0.4` |

## Rules

1. Node ids are unique and match their type's pattern.
2. Every edge endpoint exists, and has the node types the edge type requires.
3. Multiplicities in the edge-type table hold.
4. No duplicate edges (same `from`, `to`, `type`).
5. A system, department or task field belongs to the same municipality as the edges that connect it (e.g. `funded_from` stays within one municipality).
6. `spends_on.budget_2025_keur` equals the task field's `budget_2025_keur`.
7. Task-field budgets equal the sum of the matching rows in `iv3_2025.csv` (checked for every task field).
8. Every system's `source_ref` is an `algorithm_id` in the current register file.
9. `n_municipalities` equals the number of distinct municipalities of the systems linked to the supplier.
