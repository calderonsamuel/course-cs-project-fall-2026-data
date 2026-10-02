# Project status: data pipeline and the role of agents

Status as of 2 October 2026.

## 1. What the project does

The prototype predicts where a law's real-world implementation cost will land, before that cost surprises anyone. The starting observation is that legislative debate and formal impact assessments routinely miss costs that only appear during implementation, especially costs added late in the process, after the impact assessment was written.

The method is to turn a policy text into structured obligations, map them onto a real organization's systems, budgets and suppliers, and flag where obligations concentrate, with particular attention to obligations added after the impact assessment. The first case is the EU AI Act (Regulation (EU) 2024/1689) applied to three Dutch municipalities: Amsterdam, Den Haag and Terneuzen. The method is meant to transfer to other policy, such as corporate HR policy, later.

The course requires the assessment to be done by distributed cooperating agents that differ in the data they can access, compared against a single-agent baseline.

Related documents:

- [../project-plan.md](../project-plan.md): source selection and the reasons behind it (step 1).
- [schemas/](schemas/README.md): field-level schemas of every file, and the validator.
- [org-graph-schema.md](org-graph-schema.md): design of the organization graph.

## 2. Pipeline at a glance

| Step | What | Status |
|---|---|---|
| 1 | Source selection and download | **Done.** Final act, 2021 proposal, national algorithm register, CBS budgets |
| 2 | Legislative extraction | **Rule-based pass done.** Provision units, proposal-to-final alignment, 1,217 normative statements. LLM pass not started |
| 3 | Organization modeling | **First version built.** 127 systems, 207 budget lines, 42 suppliers |
| 4 | Multi-agent impact assessment | **Not started.** Section 5 describes what it needs to do |
| 5 | Validation against VNG and PBLQ estimates | **Not started.** Sources located, not read |
| 6 | Single-agent baseline | **Not started** |

```
EUR-Lex ──► provisions ──► alignment ──► obligations (rules) ─┐
                                                              ├──► agents ──► cost hotspots ──► validation
register + CBS + reference tables ──► organization graph ─────┘               (VNG, PBLQ: hidden from agents)
```

Everything up to the arrow into the agents is deterministic R code: no LLM, reproducible, and checked by `scripts/validate_schemas.R` (702 checks, 701 pass, 1 known warning).

## 3. What exists today

### Legislation side

| Layer | Script | Output | Content |
|---|---|---|---|
| Raw text | `download_ai_act.R`, `download_proposal_xhtml.R` | `data/raw/ai_act/`, `data/raw/proposals/` | Final act as Formex XML (structured), 2021 proposal as XHTML (no Formex exists for proposals), metadata notices |
| Provision units | `parse_provisions.R` | `data/processed/provisions/` | Final act: 1,638 units (180 recitals, 113 articles, 13 annexes, 68 definitions). Proposal: 835 units (89 recitals, 85 articles, 9 annexes, 44 definitions). Stable ids down to point level, e.g. `32024R1689:art26.par9` |
| Alignment | `align_versions.R` | `data/processed/alignment/` | Every final-act unit classified against the proposal. Articles and annexes: 567 added, 392 modified, 115 split or merged, 82 minor edits, 117 unchanged; 47 proposal units deleted |
| Obligations | `extract_obligations.R` | `data/processed/obligations/` | Final act: 1,217 statements (944 duties, 31 prohibitions, 158 permissions, and smaller groups). Each has addressee, condition, action, timing, references, application date, and its proposal-to-final status. Proposal: 585 statements |

Key figures from the final act:

- 975 duties and prohibitions; **387 of them sit in text added after the 2021 proposal**, 348 in modified text.
- 33 duties name deployers (the role municipalities have); 24 of those were added after the proposal. Four are specific to the public sector, including the registration duty for public-authority deployers (Art. 26(8)) and the fundamental rights impact assessment (Art. 27).
- 430 duties have no identifiable addressee in the text (mostly passive sentences such as "High-risk AI systems shall be designed…"). These are left open on purpose; see section 5.

### Organization side

| Layer | Script | Output | Content |
|---|---|---|---|
| Algorithm register | `download_algorithm_register.R` | `data/raw/algorithm_register/` | 1,573 current descriptions, 2,980 with version history; 127 belong to our municipalities (Amsterdam 72, Den Haag 44, Terneuzen 11) |
| Municipal budgets | `download_cbs_iv3.R` | `data/raw/cbs_iv3/` | CBS Iv3 2025, budget and annual accounts per task field and economic category; 67,860 rows. Expenses: Amsterdam €6.8 bn, Den Haag €3.3 bn, Terneuzen €0.23 bn (budget) |
| Reference tables | edited by hand | `data/reference/` | Theme → budget line (35 rows), keyword rules (17), supplier aliases (50) |
| Organization graph | `build_org_graph.R` | `data/processed/org_graph/` | 3 municipalities, 14 departments, 127 systems, 42 suppliers, 207 budget lines; 607 edges |

Key findings from the organization data:

- **Self-classification is inconsistent.** Den Haag marks its automated face comparison for non-resident registration (RNI) as a high-risk AI system; Amsterdam lists what appears to be the same national process as merely "impactful". Amsterdam marks none of its benefit-related systems as high-risk, although benefit eligibility is listed in Annex III point 5(a). Only 2 of 127 systems are self-classified as high-risk.
- **Small municipalities buy rather than build.** Terneuzen's systems are mostly supplier products (Centric, Visma, Microsoft), so part of its AI Act cost depends on its suppliers.
- **Budget lines are reachable.** Each system links to one or more budget lines; for example nine Amsterdam systems sit on income support (6.3, €994 m budget) and twelve on overhead (0.4, €660 m).

### Reproducing everything

From the project root, in this order:

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

The four download scripts contact external services; the rest only read local files.

## 4. Known limitations

| Area | Limitation | Effect |
|---|---|---|
| Obligations | 44% of duties have no identified addressee | Rules cannot tell who must act in passive sentences |
| Obligations | Actions are raw sentence text, not normalised | No way yet to say "this is a registration duty" or "this needs staff time" |
| Obligations | Application dates follow Article 113 as adopted in 2024 | The Digital Omnibus (Regulation (EU) 2026/1744) moved several dates; not yet reflected |
| Alignment | Only proposal vs final | Cannot say whether Parliament or the Council added a provision; their negotiating texts are not on EUR-Lex |
| Alignment | 127 low-confidence pairings | Need review before relying on them |
| Organization | Theme-to-budget mapping is coarse | 17 Amsterdam systems land on a €21 m planning line; 6 systems have no budget line |
| Organization | Departments known for 37 of 127 systems, mostly Den Haag | Department-level analysis only possible for Den Haag |
| Organization | Registers are incomplete | Registration was voluntary for years, so the graph undercounts systems |
| Generality | Actor categories, renames and dates are AI Act–specific | A new act needs a per-act configuration; updates (consolidated versions) need new fields |

## 5. What we need agents for

The deterministic pipeline stops where reading comprehension starts. Every remaining question requires reading free text in context: legal text whose addressee is implied, register descriptions written by municipal staff, and the link between the two. That is the work for agents.

The course requires the agents to differ by the data they can access, not only by prompt. The split below follows the data boundaries that already exist in the pipeline. Each agent writes into the existing schemas, with `source = agent:<name>` and citations to unit ids or register fields, so the validator can check its output the same way it checks the deterministic layers.

### Agent roles

| Agent | Sees | Does not see | Task | Output |
|---|---|---|---|---|
| **Legal extraction** | Provision units, rule-based obligations, alignment | Organization data | Assign the implied addressee for the 430 open duties; normalise each action; classify the type of effort (new process, documentation, registration, notification, human oversight, training, assessment); resolve cross-references | Obligations v2: rule fields kept, new fields added |
| **System classification** | Register texts of each system; AI Act Art. 3 (definitions), Art. 6 and Annex III only | Other obligations, budgets, self-classification of other municipalities | Decide for each system whether it is an AI system, whether it falls under an Annex III point, and whether the municipality is deployer or provider | `aiact_class`, `aiact_role` on system nodes, with the register sentences and Annex III point cited |
| **Applicability** | Obligations v2, classified systems | Budgets, suppliers | Decide which obligations apply to which system, checking each condition (high-risk, public authority, Annex III 5(b)/(c) for the fundamental rights impact assessment, …) | `applies_to` edges: obligation → system, with the condition and evidence |
| **Cost location** | Organization graph (budget lines, departments, suppliers), `applies_to` edges | Legal text beyond the obligation records | Decide where each applicable obligation's effort lands: domain budget line, overhead, or supplier; give a magnitude class; note existing capacity (an existing DPIA lowers the effort of Art. 26(9)) | Cost hotspot records per municipality |
| **Adversarial reviewer** | The other agents' outputs; the proposal-to-final delta; the Commission impact assessment if decided (see section 7) | Validation data | Look specifically for costs the ex-ante assessment could not have seen: obligations added after the proposal, conditions that pull many systems in, duties that fall on overhead functions nobody budgeted for. Challenge claims without citations | Review findings; rejected or amended hotspots |
| **Single-agent baseline** | All of the above at once | Validation data | The whole task in one pass | Same output schema as the multi-agent system |

### Why these splits are real, not personas

- **Classification without the obligations** keeps the Annex III decision from being steered by which duties would follow from it.
- **Classification without other municipalities' self-classification** tests the system description on its own merits; that is exactly where Den Haag and Amsterdam disagree today.
- **Cost location without the full legal text** forces it to work from the structured obligation records, so its claims can be traced to specific obligations.
- **The reviewer with the delta** is the only agent that knows which duties were added late, which is the core of the thesis.
- **The baseline with everything** shows whether the separation does any work: if it produces the same hotspots, the distribution is decoration.

### Rules all agents follow

- Every claim cites a unit id, an obligation id or a register field. Claims without a citation are rejected.
- LLMs know the AI Act and commentary about it. Answers must come from the supplied text, and citations are checked against the files.
- VNG and PBLQ material is never in any agent's input. It is used only in step 5.
- Agent output extends the existing schemas; it never overwrites a deterministic field.

## 6. Validation plan (step 5)

The agents' hotspots will be compared with two independent ex-ante estimates, kept outside every agent's input:

- VNG implementation analysis of the AI Act (December 2024, qualitative, expert groups from about 60 municipalities).
- PBLQ cost model for AI Act deployer obligations (standard cost model; eight municipalities and eight provinces). Availability of the model and figures still unknown.

A scoring measure still has to be defined, for example the overlap between the obligations the agents flag as costly and those VNG names, and the rank correlation with PBLQ effort estimates where they exist.

## 7. Open decisions

1. **LLM provider and budget** for the agents, and whether the first LLM pass runs on all 975 duties or starts with the 430 without an addressee.
2. **Commission impact assessment** (SWD(2021) 84): input for the adversarial reviewer, or a benchmark kept out like VNG and PBLQ.
3. **Reference tables**: review of the theme map, keyword rules and supplier aliases in `data/reference/`.
4. **Organization graph questions**: budget lines or departments as the unit for Den Haag; whether to keep systems that are out of use; budget or annual accounts as the reference figure.
5. **Generality**: per-act configuration for new acts, and support for consolidated versions (needed for the Digital Omnibus).

## 8. Next steps

1. Settle decisions 1 and 2.
2. Define the output schemas for the agents (obligations v2, system classification, `applies_to` edges, cost hotspots) in `docs/schemas/` and extend the validator, before any agent runs.
3. Build the legal extraction and system classification agents first; they unblock the other two.
4. Build applicability, cost location and the reviewer; then the single-agent baseline with the same output schema.
5. Read the VNG analysis and define the scoring measure.
