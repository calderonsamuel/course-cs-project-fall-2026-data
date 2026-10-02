# Layer 2: provision units

Script: `parse_provisions.R`. Files: `data/processed/provisions/<CELEX>.jsonl`, one per document (now `32024R1689` final act, `52021PC0206` 2021 proposal).

A provision unit is one structural piece of a legal text: a recital, a heading level, an article, a paragraph, a subparagraph, a point, an annex or an annex section. Units form a tree; rows are in document order and a parent always comes before its children.

## Fields

| Field | Type | Required | Content |
|---|---|---|---|
| `unit_id` | id | yes | `<celex>:<path>`; unique across all files |
| `celex` | id | yes | Document, CELEX pattern |
| `version` | enum | yes | `final_2024`, `proposal_2021` |
| `seq` | integer | yes | Document order, `1..n` without gaps |
| `type` | enum | yes | `recital`, `title`, `chapter`, `section`, `article`, `paragraph`, `subparagraph`, `point`, `annex`, `annex_section` |
| `path` | string | yes | Position inside the document, see below; unique within the file |
| `parent_id` | id | no | `unit_id` of the parent; `null` for top-level units (recitals, top headings, annexes) |
| `depth` | integer | yes | 0 for top-level units, parent's depth + 1 otherwise |
| `num` | string | no | Numbering as printed: `Article 5`, `1.`, `(a)`, `CHAPTER III`, `ANNEX III`. `null` for unnumbered units |
| `label` | string | yes | Normalised number: `5`, `1`, `a`, `III`; for subparagraphs the position (`1`, `2`) |
| `heading` | string | no | Title of chapters, sections, articles, annexes and annex sections |
| `text` | string | yes, may be empty | The unit's own text, without its children. Empty string when everything sits in children. Where children interrupt the own text, `[…]` marks the gap |
| `full_text` | string | yes | Own text plus all descendants with their numbering |
| `division` | string | no | Path of the enclosing chapter, section, title or annex |
| `article` | string | no | Article label, for articles and everything inside them |
| `source_file` | string | yes | Raw file the unit was read from |
| `source_ref` | string | no | Formex `IDENTIFIER` (final act) or XHTML paragraph index `p<n>` (proposal) |
| `notes` | string | no | Parser warnings, e.g. `numbering corrected: source shows (1)` |

## Paths

A path is a chain of segments separated by `.`. Articles are not nested under chapters in the path, because article numbers are unique.

| Segment | Unit | Example |
|---|---|---|
| `rct<n>` | Recital | `rct12` |
| `ti<roman>`, `ch<roman or number>`, `sec<n>` | Title, chapter, section | `chIII.sec2`, `tiIII.ch1` |
| `art<n>` | Article | `art26` |
| `par<n>` | Paragraph | `art26.par9` |
| `sub<n>` | Subparagraph (final act only) | `art5.par1.sub1` |
| `pt_<label>` | Point; dots in the label become `-` | `art5.par1.sub1.pt_h`, `anxVII.pt_3-1` |
| `anx<roman>` | Annex | `anxIII` |
| `sec<letter or n>` | Annex section | `anxVIII.secA` |
| `_dup<n>` suffix | Second unit with the same path | Should not occur; reported in `notes` |

## Rules

1. `unit_id` is unique and equals `celex + ":" + path`.
2. `seq` runs from 1 to the number of rows.
3. Every `parent_id` refers to a unit in the same file that comes earlier (`seq` smaller).
4. `depth` is 0 without a parent and parent depth + 1 with one.
5. Type-specific paths: recitals `rct<n>`, articles `art<n>`, annexes `anx<roman>`.
6. `article` is set for articles and all their descendants, and equals the article's label.
7. `full_text` contains `text`.
8. Counts match the published document:

| Document | Recitals | Articles | Annexes | Definitions in Article 3 |
|---|---|---|---|---|
| `32024R1689` | 180 | 113, numbered 1–113 | 13 | 68 |
| `52021PC0206` | 89 | 85, numbered 1–85 | 9 | 44 |

9. No path ends in `_dup<n>` (warning, not failure: the parser keeps the unit and records why).
