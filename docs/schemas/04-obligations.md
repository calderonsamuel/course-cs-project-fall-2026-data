# Layer 4: obligations

Script: `extract_obligations.R`. Files: `data/processed/obligations/<CELEX>.jsonl` (now `32024R1689`, `52021PC0206`).

One record per normative statement: a sentence containing a modal phrase (`shall`, `may`, `must`, `is prohibited`, …), or one point of a list whose introduction contains it. Recitals and the Article 3 definitions are skipped. This is the rule-based pass (`method = rules_v1`); a later LLM pass will add fields, not change these.

## Fields

| Field | Type | Required | Content |
|---|---|---|---|
| `obligation_id` | id | yes | `<unit_id>#<n>`, `n` counting statements within the unit from 1; unique |
| `celex` | id | yes | Document |
| `version` | enum | yes | `final_2024`, `proposal_2021` |
| `unit_id` | id | yes | Provision unit holding the span |
| `chapeau_id` | id | no | For list points: the unit with the introduction the modal came from. `null` otherwise |
| `article` | string | no | Article label; `null` in annexes |
| `division` | string | yes | Enclosing chapter, section, title or annex path |
| `span` | string | yes | The statement as written |
| `span_start`, `span_end` | integer | yes | Character offsets of `span` in the unit's `text`, 1-based, inclusive |
| `statement_type` | enum | yes | `duty`, `prohibition`, `permission`, `power`, `applicability`, `deeming` |
| `modal` | enum | yes | `shall`, `shall not`, `must`, `must not`, `may`, `may not`, `is prohibited`, `are prohibited`, `is required to`, `are required to` |
| `addressee_text` | string | yes, may be empty | Grammatical subject before the modal |
| `actors` | list | no | Actor categories named in the subject, `;`-separated; `null` when none |
| `primary_actor` | enum | yes | First actor, or `unspecified` |
| `actor_basis` | enum | yes | `subject`, `clause`, `pronoun`, `none` |
| `public_sector` | boolean | yes | Subject or condition names public authorities, bodies governed by public law, public services or law enforcement |
| `condition` | string | no | Leading conditional clause |
| `action` | string | yes | Text after the modal; for list points the introduction's action, `—`, and the point text |
| `timing` | list | no | Time limits found, `;`-separated |
| `applies_from` | date | no | Application date under Article 113 as adopted in 2024. Final act only; `null` for annexes and for the proposal |
| `references` | list | no | Cross-references found, `;`-separated |
| `delta_status` | enum | no | Alignment status of `unit_id` (layer 3). Final act only |
| `delta_old_id` | id | no | Matched proposal unit, from layer 3 |
| `delta_score` | number | no | From layer 3 |
| `delta_confidence` | enum | no | From layer 3 |
| `method` | enum | yes | `rules_v1` |

**Actor categories:** `gpai_provider`, `deployer`, `provider`, `importer`, `distributor`, `authorised_representative`, `product_manufacturer`, `operator`, `notified_body`, `notifying_authority`, `market_surveillance_authority`, `national_competent_authority`, `member_state`, `commission`, `ai_office`, `board`, `scientific_panel`, `advisory_forum`, `edps`, `union_institutions`, `public_authority`. In the 2021 proposal, "user" is read as `deployer`.

**Actor basis:**

| Value | Meaning | `primary_actor` |
|---|---|---|
| `subject` | Named in the subject | an actor |
| `clause` | Named in the text before the modal, when the subject split failed | an actor |
| `pronoun` | "it" / "they" resolved to an earlier statement's actor | an actor |
| `none` | Passive or object subject; left for the LLM pass | `unspecified` |

## Rules

1. `obligation_id` is unique and starts with `unit_id + "#"`.
2. Every `unit_id` and `chapeau_id` exists in the provisions file of the same document.
3. `span` equals the unit's `text` from `span_start` to `span_end`.
4. For list points (`chapeau_id` set), the span is the whole point text.
5. `primary_actor` is `unspecified` exactly when `actor_basis` is `none`, and otherwise is the first entry of `actors`.
6. Every entry in `actors` is an actor category.
7. For the final act, `delta_status`, `delta_old_id`, `delta_score` and `delta_confidence` equal the alignment row of `unit_id`, and every obligation has one (spans always come from units with text, and every such unit is aligned).
8. For the proposal, all `delta_*` fields and `applies_from` are `null`.
9. `applies_from` is one of `2025-02-02`, `2025-08-02`, `2026-08-02` for final-act articles.
