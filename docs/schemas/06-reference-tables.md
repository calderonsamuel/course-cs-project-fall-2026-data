# Reference tables

Hand-edited CSV files in `data/reference/` that steer the organization graph. They are meant to be reviewed and changed; the graph is rebuilt from them. All columns are read as text.

## `theme_to_taakveld.csv`

Maps a register policy theme to candidate budget lines. A theme can map to several task fields.

| Column | Type | Required | Content |
|---|---|---|---|
| `theme` | string | yes | Value from the register's `category` field |
| `taakveld` | string | yes | BBV code; key in `data/raw/cbs_iv3/dim_taakveld.csv` |
| `taakveld_title` | string | yes | Title, for readers; must match the code |
| `confidence` | enum | yes | `high`, `medium`, `low`. The graph uses `high` and `medium` only |
| `note` | string | no | Why |

Rules: (`theme`, `taakveld`) unique; every theme used in the register for the three municipalities has at least one row; `taakveld_title` matches the CBS title (ignoring the code prefix and CBS's truncation with `..`).

## `taakveld_keywords.csv`

Keyword rules applied to a system's name and short description. When any rule fires, the theme map is not used for that system.

| Column | Type | Required | Content |
|---|---|---|---|
| `pattern` | string | yes | Perl-compatible regular expression, matched against lower-case text; unique |
| `taakveld` | string | yes | BBV code; key in `dim_taakveld.csv` |
| `taakveld_title` | string | yes | Title, must match the code |
| `note` | string | no | |

Rules: every pattern compiles.

## `supplier_aliases.csv`

Maps raw `provider` text from the register to canonical suppliers.

| Column | Type | Required | Content |
|---|---|---|---|
| `raw` | string | yes | Provider text exactly as in the register (whitespace collapsed); unique |
| `suppliers` | list | when `kind = vendor` | Canonical names, `;`-separated |
| `kind` | enum | yes | `vendor`, `in_house`, `open_source`, `none`, `unknown` |
| `note` | string | no | |

Rules: `suppliers` is filled exactly when `kind` is `vendor`; every `provider` value of the three municipalities has a row (otherwise the graph falls back to a low-confidence rule, reported as a warning).
