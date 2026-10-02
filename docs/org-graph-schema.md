# Organization graph: design

Pipeline step 3. The graph models what exists inside a municipality to absorb an obligation: systems, who runs them, who supplies them, and which budget line pays for them. Step 4 attaches obligations to it.

Scope: Amsterdam (GM0363), Den Haag (GM0518), Terneuzen (GM0715).

This page explains the design. The field-level reference, with every field, type and rule, is [schemas/05-org-graph.md](schemas/05-org-graph.md); `scripts/validate_schemas.R` checks the graph against it.

## Sources

| Source | File | Gives |
|---|---|---|
| National algorithm register, current | `data/raw/algorithm_register/algoritmeregister_NLD_current.csv` | Systems, theme, AI Act self-classification, supplier, impact assessments |
| Same, with version history | `..._history.csv` | `department` from older versions of the publication standard |
| CBS Iv3 2025, table 45071NED | `data/raw/cbs_iv3/iv3_2025.csv` | Spending per task field and economic category, budget and annual accounts |
| `data/reference/theme_to_taakveld.csv` | hand-edited | Register theme to Iv3 task field |
| `data/reference/taakveld_keywords.csv` | hand-edited | Keyword rules that refine the theme mapping per system |
| `data/reference/supplier_aliases.csv` | hand-edited | Raw `provider` text to one or more supplier names, and a kind |

## Principles

- Every node and edge records where it came from (`source`, `source_ref`) and how sure we are (`confidence`).
- Missing facts stay missing. A system with no supplier in the register gets no `supplied_by` edge; nothing is guessed.
- Fields reserved for agents (`aiact_class`, `aiact_role` on systems) stay `null` until step 4, which fills them with the agent's name as `source`.

## Shape

Five node types: municipality, department, system, supplier, task field (a BBV budget line per municipality). Seven edge types:

| Edge | From → to | How it is derived |
|---|---|---|
| `operates` | municipality → system | register `organization` |
| `has_department` | municipality → department | register history |
| `runs` | department → system | latest register version that still named a department; medium confidence because it is an older version |
| `supplied_by` | system → supplier | register `provider` through the alias table; one value can name several suppliers (Civinc with an OpenAI model inside gives two edges) |
| `funded_from` | system → task field | keyword rule first, else theme map; can point to several task fields, each with its own confidence |
| `spends_on` | municipality → task field | CBS Iv3 |
| `overhead_of` | task field 0.4 → municipality | fixed |

Departments are known mainly for Den Haag (the older register standard had the field; Amsterdam rarely filled it, Terneuzen never).

## Where compliance cost lands

An obligation on a system lands in two places, and the graph keeps both reachable:

1. The domain task field that runs the system (`funded_from`), e.g. 6.3 for a benefits model. Staff time for human oversight, monitoring and informing affected persons.
2. Task field 0.4 Overhead. Central functions that typically carry the cross-cutting duties: privacy officer and DPIA/FRIA work, legal, procurement, IT, AI literacy training.

The economic categories split each further: own staff (L1.1), hired staff (L3.5.1), suppliers (L3.8). A supplier-built system shifts part of the provider-side cost to the supplier, which matters for Terneuzen, where most systems are bought.

## Not modelled yet

- Processes and services as separate nodes. The register has no process field; the `goal` text describes the process and agents can read it.
- Shared-service organisations (e.g. a regional IT cooperation). Not visible in the register; would need municipal annual reports.
- Systems missing from the register. Registration was voluntary for a long time, so the graph undercounts; this is recorded as a known limitation, not filled in.

## Open questions

1. Is a task field the right unit for "where cost lands", or should departments be the main unit for Den Haag where they exist?
2. Should systems that are out of use be kept (they show history) or dropped (no future cost)? Draft: keep, with `status`, and let agents ignore them.
3. Budget (Begroting) or annual accounts (Jaarrekening) as the reference figure? Draft: both when available; budget as the default because it exists for every municipality.
