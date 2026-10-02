# Layer 3: version alignment

Script: `align_versions.R <OLD> <NEW>`. Files in `data/processed/alignment/`:

- `<OLD>__<NEW>.jsonl`: one row per unit of the newer version that has text, plus one row per deleted unit of the older version.
- `<OLD>__<NEW>_containers.csv`: which older article or annex became which newer one.

Now present: `52021PC0206__32024R1689` (2021 proposal to final act).

## Unit alignment fields

| Field | Type | Required | Content |
|---|---|---|---|
| `new_id` | id | no | Unit in the newer version; `null` only for `deleted` rows |
| `old_id` | id | no | Matched unit in the older version; `null` for `added` rows |
| `status` | enum | yes | See below |
| `score` | number | no | TF-IDF cosine similarity of the two texts, 0–1, three decimals. For `deleted` rows: the best similarity any newer unit reached. `null` for `added` |
| `confidence` | enum | no | `high` (identical or score ≥ 0.6), `medium` (≥ 0.45), `low`; `null` for `added` and `deleted` |
| `container_match` | boolean | no | `true` when both units sit in containers matched to each other; `null` for `added` and `deleted` |
| `type` | enum | yes | Unit type (from layer 2), of the newer unit, or of the older unit for `deleted` |
| `new_container` | string | no | `art<n>` or `anx<roman>` of the newer unit |
| `old_container` | string | no | Same for the older unit |
| `new_text` | string | no | Own text of the newer unit |
| `old_text` | string | no | Own text of the older unit |

## Status values

| Status | Meaning | `new_id` | `old_id` | `score` |
|---|---|---|---|---|
| `unchanged` | Identical after normalisation | set | set | set |
| `minor_edit` | One-to-one match, score ≥ 0.90 | set | set | ≥ 0.90 |
| `modified` | One-to-one match, score < 0.90 | set | set | < 0.90 |
| `split_merge` | No one-to-one partner, but an older unit with score ≥ 0.35 | set | set | ≥ 0.35 |
| `added` | No older unit with score ≥ 0.35 | set | `null` | `null` |
| `deleted` | Older unit with no partner and no newer unit ≥ 0.35 | `null` | set | < 0.35 |

A `modified` score may be below 0.35 (down to 0.25) when both units keep the same number inside matched containers.

## Container alignment fields (CSV)

| Column | Type | Required | Content |
|---|---|---|---|
| `new_container` | string | yes | `art<n>` or `anx<roman>` in the newer version; unique |
| `new_heading` | string | no | Its heading |
| `old_container` | string | yes | Matched container in the older version; unique |
| `old_heading` | string | no | Its heading |
| `score` | number | yes | 0.8 × body similarity + 0.2 × heading similarity, ≥ 0.30 |

## Rules

1. Every `new_id` exists in the newer provisions file and every `old_id` in the older one.
2. Each `new_id` appears once. Each `old_id` appears in at most one one-to-one row (`unchanged`, `minor_edit`, `modified`); `split_merge` rows may reuse it.
3. Every newer unit with non-empty `text` has exactly one row.
4. The id/score pattern in the status table holds for every row.
5. `new_text` and `old_text` equal the `text` of the referenced units.
6. Container pairs are one-to-one, and every container named in the CSV exists in the matching provisions file.
