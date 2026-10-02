# Layer 1: raw sources

Files in `data/raw/` are kept exactly as downloaded, except where noted. Each download writes a manifest with the source URL, retrieval time and MD5 checksum of every file, so a file can be checked against what was received.

Only the parts of each external format that the pipeline relies on are documented here. If a source changes these parts, the parsers break, and the validator should catch it.

## EUR-Lex: final AI Act

Script: `download_ai_act.R`. Folder: `data/raw/ai_act/`.

| File | Content |
|---|---|
| `fmx4/*.fmx.xml` | Formex 4 XML, unzipped from `32024R1689_fmx4.zip` |
| `32024R1689_fmx4.zip` | The zip as received |
| `32024R1689_en.xhtml` | XHTML rendering, used as a cross-check |
| `32024R1689_notice_tree.xml` | Cellar metadata notice, level "tree" |
| `32024R1689_manifest.json` | Manifest |

**Formex files.** Exactly one file has root element `ACT` (the main text); every annex is a separate file with root `ANNEX`; `.doc.fmx.xml` (root `DOC`) and `.toc.fmx.xml` (root `PUBLICATION`) describe the publication.

Elements the parser relies on:

| Element | Meaning |
|---|---|
| `PREAMBLE//CONSID/NP` with `NO.P` | Recital and its number |
| `ENACTING.TERMS/DIVISION` with `TITLE/TI`, `TITLE/STI` | Chapter or section, its number and heading |
| `ARTICLE` with `@IDENTIFIER`, `TI.ART`, `STI.ART` | Article, number, heading |
| `PARAG` with `@IDENTIFIER`, `NO.PARAG` | Numbered paragraph |
| `ALINEA` | Unnumbered subparagraph or text block |
| `LIST/ITEM/NP` with `NO.P`, `TXT` | Point |
| `GR.SEQ` with `TITLE` | Section inside an annex |
| `QUOT.START`, `QUOT.END` with `@CODE` | Quotation marks, as a Unicode code point in hex |
| `QUOT.S` | Quoted text inserted into another act (Articles 102–110) |
| `NOTE` | Footnote, dropped from the text |

**Manifest** (`32024R1689_manifest.json`):

| Key | Content |
|---|---|
| `celex`, `eli`, `cellar_url`, `language`, `title` | Identity of the act |
| `retrieved_at`, `eurlex_version`, `r_version` | When and with what |
| `notice` | `file`, `bytes`, `md5`, `level`, `manifestation_types` |
| `fmx4` | `retrieved`, `http_status`, `source_url`, `zip`, `files` (each `file`, `bytes`, `md5`, `root`), `counts`, `counts_match_expected` |
| `xhtml` | `retrieved`, `http_status`, `source_url`, `file`, `counts`, `counts_match_expected` |
| `expected` | `recitals` 180, `articles` 113, `annexes` 13 |

Rules: every `md5` matches the file on disk; `counts` equal `expected` for both formats.

## EUR-Lex: Commission proposals

Script: `download_proposal_xhtml.R <CELEX>`. Folder: `data/raw/proposals/<CELEX>/`. Proposals have no Formex version.

| File | Content |
|---|---|
| `<CELEX>_en_<n>.xhtml` | One file per document item, in the order Cellar lists them. For `52021PC0206`: 1 = main text, 2 = annexes |
| `<CELEX>_manifest.json` | `celex`, `cellar_url`, `language`, `retrieved_at`, `items` (each `file`, `source_url`, `bytes`, `md5`) |

XHTML paragraph classes the parser relies on (the `li ` prefix is ignored):

| Class | Meaning |
|---|---|
| `Formuledadoption` … `Fait` | Start and end of the enacting terms |
| `ManualConsidrant` | Recital |
| `SectionTitle` | Title or chapter heading line (`TITLE I`, then its heading) |
| `Titrearticle` | Article number and heading, in two `span`s |
| `ManualNumPar1`, `NumPar1` | Numbered paragraph (number in `span.num`); `NumPar1` without a number is a follow-on subparagraph |
| `Point0`, `Point0number`, `Point1`, `Point2` | Points at three levels |
| `Normal`, `Text1` | Unnumbered text |
| `Annexetitre` | Annex title; may also contain the first section heading |
| `NumPar1`, `NumPar2`, `Point0letter`, `Point1letter` | Items inside annexes |

Rule: every `md5` matches the file on disk.

## EUR-Lex: metadata notices

Folder: `data/raw/metadata/`. Files `<CELEX>_notice_tree.xml`, Cellar "tree" notices downloaded with `eurlex::elx_download_xml`. Used for discovery only (formats available, related documents); nothing downstream parses them yet.

## National algorithm register

Script: `download_algorithm_register.R`. Folder: `data/raw/algorithm_register/`. Source: official download endpoints of algoritmes.overheid.nl, language `NLD`.

| File | Rows (2026-10-02) | Content |
|---|---|---|
| `algoritmeregister_NLD_current.csv` | 1,573 | Current description of every algorithm, all organisations |
| `algoritmeregister_NLD_history.csv` | 2,980 | All published versions, including older publication standards |
| `algoritmeregister_manifest.json` | | Manifest |

Columns the pipeline uses (the files have more; the full lists are in the manifest under `current.columns` and `history.columns`):

| Column | Used for |
|---|---|
| `algorithm_id` | System id; join key between current and history |
| `organization`, `org_id` | Municipality |
| `name`, `description_short`, `goal` | System description |
| `category` | Policy themes, comma-separated |
| `status` | `In gebruik`, `In ontwikkeling`, `Buiten gebruik` |
| `publication_category` | Self-classification: `Hoog-risico AI-systeem`, `Impactvolle algoritmes`, `Overige algoritmes` |
| `provider` | Supplier, free text |
| `impacttoetsen`, `impacttoetsen_grouping` | Impact assessments listed |
| `human_intervention`, `risks`, `methods_and_models`, `source_data`, `lawful_basis` | Text kept for agents |
| `begin_date`, `end_date`, `publication_dt` | Dates |
| `department` (history file only) | Department, from older standard versions |

Manifest keys: `source`, `api_description`, `language`, `retrieved_at`, `r_version`, `municipality_patterns`, and for `current` and `history` each: `url`, `status`, `content_type`, `file`, `bytes`, `md5`, `separator`, `n_rows`, `columns`, `organisation_column`, `rows_per_municipality`, `n_organisations`.

Rules: every `md5` matches; `n_rows` matches the file; every used column exists; `algorithm_id` is unique in the current file.

## CBS Iv3 municipal budgets

Script: `download_cbs_iv3.R`. Folder: `data/raw/cbs_iv3/`. Source: table 45071NED, *Gemeenten 2025 onbewerkte Iv3-data*, dataderden.cbs.nl. Keys are stored trimmed (CBS pads them with spaces).

**`iv3_2025.csv`**, one row per municipality × report × task field or balance item × category:

| Column | Type | Required | Content |
|---|---|---|---|
| `ID` | integer | yes | CBS row id, unique |
| `TaakveldBalanspost` | string | yes | Task field (`0.1`–`8.3`) or balance item (`A…`, `P…`); key in `dim_taakveld.csv` |
| `Categorie` | string | yes | Economic category; key in `dim_categorie.csv`. `L…` expenses, `B…` income, `Primo`/`Ultimo` balance |
| `Gemeenten` | id | yes | `GM0363`, `GM0518` or `GM0715` |
| `Verslagsoort` | enum | yes | `2025X000` budget, `2025X005` annual accounts |
| `release1_keur` | integer | no | First release, thousand euro; `null` when not delivered. May be negative |
| `release2_keur` | integer | no | Second release with corrections; same rules |

Rules: (`TaakveldBalanspost`, `Categorie`, `Gemeenten`, `Verslagsoort`) is unique; every municipality × report has rows.

**Dimension tables** `dim_taakveld.csv`, `dim_categorie.csv`, `dim_verslagsoort.csv`, `dim_gemeenten.csv`: columns `Key`, `Title`, `Description`; `Key` unique.

**Manifest** `iv3_2025_manifest.json`: `source`, `table`, `retrieved_at`, `r_version`, `unit`, `municipalities`, `reports`, `n_rows`, `columns`, `summary` (per municipality × report: `rows`, rows with values per release, `total_expenses_keur`). It has no checksum; the row count is checked instead.
