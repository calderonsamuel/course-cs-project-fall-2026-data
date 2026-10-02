# AI Act implementation-cost prototype

Predicts where the real-world implementation cost of a law will land, starting with the EU AI Act (Regulation (EU) 2024/1689) and three Dutch municipalities: Amsterdam, Den Haag and Terneuzen. Legal text is turned into structured obligations, municipalities into a graph of systems, suppliers and budget lines, and agents will connect the two.

**Status:** the deterministic data pipeline runs end to end and passes schema validation. The agents are not built yet. Details in [docs/project-status.md](docs/project-status.md).

## Layout

```
scripts/          R scripts, one per pipeline step
data/raw/         downloads as received, with manifests
data/processed/   provisions, alignment, obligations, organization graph
data/reference/   hand-edited mapping tables
docs/             project status, schemas, validation report
```

## Running

Requires R (tested with 4.5.3) with `eurlex`, `httr2`, `xml2`, `jsonlite` and `Matrix`. From the project root:

```
Rscript scripts/download_ai_act.R
Rscript scripts/download_proposal_xhtml.R 52021PC0206
Rscript scripts/download_algorithm_register.R
Rscript scripts/download_cbs_iv3.R
Rscript scripts/parse_provisions.R
Rscript scripts/align_versions.R 52021PC0206 32024R1689
Rscript scripts/extract_obligations.R 32024R1689 52021PC0206
Rscript scripts/build_org_graph.R
Rscript scripts/validate_schemas.R
```

The first four scripts download from EUR-Lex, the national algorithm register and CBS; the rest work on local files.

## Documentation

- [docs/project-status.md](docs/project-status.md): pipeline status, findings, limitations and the planned agents
- [docs/schemas/](docs/schemas/README.md): schema of every file, and the [validation report](docs/schemas/validation-report.md)
- [docs/org-graph-schema.md](docs/org-graph-schema.md): design of the organization graph
