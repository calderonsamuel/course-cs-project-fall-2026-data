# Rule-based obligation extraction (pipeline step 2, deterministic pass).
#
# Reads provision units (scripts/parse_provisions.R) and writes one record per
# normative statement: a sentence with "shall", "shall not", "must", "may",
# "is/are prohibited" or "is/are required to". A paragraph that introduces a
# list ("Providers shall: (a) ...; (b) ...") yields one record per point, with
# the addressee and modal taken from the introductory text.
#
# Recitals (not binding) and the Article 3 definitions are skipped.
# The fields that rules handle badly (implicit addressees in passive sentences,
# normalised actions) are left for a later LLM pass; every record keeps its
# source span so that pass and any reviewer can check it.
#
# Output: data/processed/obligations/<CELEX>.jsonl, one record per statement:
#   obligation_id    "<unit_id>#<n>"
#   unit_id          provision unit holding the span; chapeau_id: unit with the
#                    introductory text when the statement comes from a list
#   article, division
#   span             the statement as written (sentence, or the point text)
#   span_start, span_end  character offsets of span in the unit's text (1-based)
#   statement_type   duty | prohibition | permission | power | applicability | deeming
#   modal            the matched modal phrase
#   addressee_text   grammatical subject before the modal ("" in some passives)
#   actors           actor categories named in the subject (";"-separated)
#   primary_actor    first actor named in the subject, or "unspecified"
#   actor_basis      "subject" (named in the subject), "clause" (named in the
#                    text before the modal when the subject split failed),
#                    "pronoun" (it/they resolved to an earlier statement's
#                    actor) or "none" (passive or object subject; left for
#                    the LLM pass)
#   public_sector    TRUE when subject or condition names public authorities,
#                    bodies governed by public law, public services or law enforcement
#   condition        leading conditional clause ("Where ...", "By way of derogation ...")
#   action           text after the modal (for list items: introduction + point)
#   timing           time limits found in the statement ("within 15 days", "by 2 August 2028")
#   applies_from     date the provision applies, from Article 113 (final AI Act only)
#   references       cross-references found in the statement (";"-separated)
#   delta_status, delta_old_id, delta_score, delta_confidence
#                    proposal -> final alignment of the unit (when an alignment file exists)
#   method           "rules_v1"
#
# Usage from the project root:
#   Rscript scripts/extract_obligations.R 32024R1689 52021PC0206

args <- commandArgs(trailingOnly = TRUE)
targets <- if (length(args)) args else c("32024R1689", "52021PC0206")
in_dir    <- file.path("data", "processed", "provisions")
align_dir <- file.path("data", "processed", "alignment")
out_dir   <- file.path("data", "processed", "obligations")

MODAL <- "\\b(shall not|must not|may not|shall|must|may|(?:is|are) prohibited|(?:is|are) required to)\\b"
CONDITION_START <- paste0("^(Where|If|When|Whenever|In the case|In cases|Unless|By way of derogation|",
                          "Without prejudice|Notwithstanding|For the purpose|For the purposes|In order to|",
                          "Prior to|Before|Upon|On the basis|Following|Once|After|Subject to|In accordance with|",
                          "Pursuant to|To the extent|As regards|With regard to|Without undue delay)\\b")

# Actor categories, checked against the lower-cased subject. Order matters:
# more specific names first.
ACTORS <- c(
  gpai_provider = "providers? of general-purpose ai models?",
  deployer = "deployers?\\b",
  provider = "providers?\\b",
  importer = "importers?\\b",
  distributor = "distributors?\\b",
  authorised_representative = "authorised representatives?",
  product_manufacturer = "product manufacturers?",
  operator = "operators?\\b",
  notified_body = "notified bod(y|ies)",
  notifying_authority = "notifying authorit(y|ies)",
  market_surveillance_authority = "market surveillance authorit(y|ies)",
  national_competent_authority = "(national )?competent authorit(y|ies)",
  member_state = "member states?\\b",
  commission = "\\bcommission\\b",
  ai_office = "\\bai office\\b",
  board = "\\bboard\\b",
  scientific_panel = "scientific panel",
  advisory_forum = "advisory forum",
  edps = "european data protection supervisor",
  union_institutions = "union institutions?",
  public_authority = "public authorit(y|ies)|bodies governed by public law"
)
PUBLIC <- "public authorit|bodies governed by public law|public services?|law enforcement|union institutions"

TIMING <- paste(c(
  "within (?:a period of )?(?:\\d+|one|two|three|four|five|six|seven|ten|twelve|fifteen|thirty)\\s+(?:working |calendar )?(?:days|months|weeks|hours|years)",
  "(?:by|before|until|no later than|from|as of) \\d{1,2} (?:January|February|March|April|May|June|July|August|September|October|November|December) \\d{4}",
  "without undue delay", "immediately", "at the latest[^,;.]*",
  "prior to (?:placing|putting|deploying|using|its|the)[^,;.]*", "before (?:placing|putting|deploying|using)[^,;.]*",
  "every (?:two|three|four|five) years", "annually", "periodically", "throughout (?:its|the|their) lifetime[^,;.]*",
  "for a period of[^,;.]*"), collapse = "|")

REFS <- paste(c(
  "Articles? \\d+(?:\\(\\d+\\))*(?:\\([a-z]+\\))*(?:,? (?:first|second|third|fourth|fifth) subparagraph)?(?:,? points? \\([a-z]+\\)(?:\\((?:i|ii|iii|iv|v|vi)\\))?)?(?: (?:to|and) \\d+(?:\\(\\d+\\))?)?",
  "Annex(?:es)? [IVXLC]+(?:,? (?:point|Section) [0-9A-Z]+)?",
  "(?:Regulation|Directive|Decision) \\((?:EU|EC|EEC)\\)(?: No)? \\d+/\\d+",
  "(?:Regulation|Directive|Decision) (?:\\(EC\\) )?(?:No )?\\d+/\\d+/(?:EC|EU|EEC)",
  "(?:this|that) Article", "paragraphs? \\d+(?: (?:to|and) \\d+)?(?: of this Article)?"), collapse = "|")

# Application dates under Article 113 of the final AI Act (as adopted in 2024).
applies_from <- function(article, division) {
  a <- suppressWarnings(as.integer(article))
  ch <- sub("\\..*$", "", division)
  ifelse(is.na(a), NA_character_,
  ifelse(ch %in% c("chI", "chII"), "2025-02-02",
  ifelse((grepl("^chIII\\.sec4", division) | ch %in% c("chV", "chVII") | (ch == "chXII" & a != 101) | a == 78),
         "2025-08-02", "2026-08-02")))
}

all_matches <- function(x, pattern) {
  m <- regmatches(x, gregexpr(pattern, x, perl = TRUE))[[1]]
  if (length(m)) paste(unique(trimws(m)), collapse = "; ") else NA_character_
}

# Sentence boundaries: a full stop followed by a capital or an opening quote.
split_sentences <- function(text) {
  gaps <- gregexpr("(?<=\\.)\\s+(?=[A-Z‘“(])", text, perl = TRUE)[[1]]
  if (gaps[1] < 0) return(data.frame(start = 1L, end = nchar(text), sentence = text, stringsAsFactors = FALSE))
  starts <- c(1L, as.integer(gaps + attr(gaps, "match.length")))
  ends <- c(as.integer(gaps) - 1L, nchar(text))
  data.frame(start = starts, end = ends, sentence = substring(text, starts, ends), stringsAsFactors = FALSE)
}

# Split a normative sentence into condition, subject, modal and action.
analyse <- function(s) {
  m <- regexpr(MODAL, s, perl = TRUE, ignore.case = FALSE)
  if (m < 0) return(NULL)
  modal <- regmatches(s, m)
  before <- substr(s, 1, m - 1); action <- trimws(substring(s, m + attr(m, "match.length")))
  condition <- NA_character_; subject <- trimws(before)
  if (grepl(CONDITION_START, before, perl = TRUE)) {
    commas <- gregexpr(",", before, fixed = TRUE)[[1]]
    if (commas[1] > 0) {
      last <- max(commas)
      condition <- trimws(substr(before, 1, last - 1))
      subject <- trimws(substring(before, last + 1))
    } else {
      condition <- trimws(before); subject <- ""
    }
  }
  list(modal = modal, condition = condition, subject = subject, action = action, before = trimws(before))
}

classify <- function(modal, subject, action) {
  a <- tolower(action); s <- tolower(subject)
  if (grepl("^this regulation|^this chapter|^this article|^this section|^th(is|ese) (obligations?|paragraph|subparagraph)", s) ||
      grepl("^(not )?apply\\b|^be without prejudice|^not (affect|prejudice|cover)|^enter into force|^not be construed|^be binding", a))
    return("applicability")
  # Inverted prohibitions: "In no case shall such a system be used ..."
  if (grepl("^(in no case|under no circumstances|at no time)$", s)) return("prohibition")
  if (grepl("^(also )?be (deemed|considered|presumed|regarded)\\b", a)) return("deeming")
  if (grepl("^be empowered|^adopt (delegated|implementing) acts?", a) ||
      (grepl("commission", s) && modal == "may" && grepl("^(by means of implementing acts, )?adopt", a)))
    return("power")
  if (modal %in% c("shall not", "must not", "may not") || grepl("prohibited", modal) || grepl("^be prohibited", a))
    return("prohibition")
  if (modal == "may") return("permission")
  "duty"
}

# Subjects that point back to an actor named earlier ("it", "they", "that provider").
PRONOUN <- "^(in such (a )?cases?, )?(it|they|he or she|this|these|those|such persons?|that person)$"

# The 2021 proposal calls deployers "users" (see RENAMES in align_versions.R).
DEPLOYER_ALIASES <- c("52021PC0206" = "\\busers?\\b")

actors_of <- function(subject) {
  s <- tolower(subject)
  if (!is.na(alias <- DEPLOYER_ALIASES[CURRENT_CELEX])) s <- gsub(alias, "deployer", s, perl = TRUE)
  pos <- vapply(ACTORS, function(p) { r <- regexpr(p, s, perl = TRUE); if (r > 0) as.numeric(r) else Inf }, 0)
  found <- names(sort(pos[is.finite(pos)]))
  # "deployers that are public authorities" is a deployer with a qualifier,
  # not a separate addressee; keep public_authority only as a sole actor
  if (length(found) > 1) found <- setdiff(found, "public_authority")
  found
}

record <- function(u, span, start, end, a, chapeau_id = NA, action = a$action) {
  acts <- actors_of(a$subject); basis <- "subject"
  # Commas inside the subject ("deployers that are bodies governed by public
  # law, or are private entities ..., shall") can make the condition split
  # cut it off; then look in the whole text before the modal.
  if (!length(acts) && !is.na(a$condition) && !grepl(PRONOUN, tolower(a$subject))) {
    acts <- actors_of(a$before); basis <- "clause"
  }
  type <- classify(a$modal, a$subject, a$action)
  ctx <- paste(a$subject, ifelse(is.na(a$condition), "", a$condition))
  data.frame(
    unit_id = u$unit_id, chapeau_id = chapeau_id, article = u$article, division = u$division,
    span = span, span_start = start, span_end = end, statement_type = type, modal = a$modal,
    addressee_text = a$subject, actors = if (length(acts)) paste(acts, collapse = ";") else NA,
    primary_actor = if (length(acts)) acts[1] else "unspecified",
    actor_basis = if (length(acts)) basis else "none",
    public_sector = grepl(PUBLIC, tolower(ctx)), condition = a$condition, action = action,
    timing = all_matches(paste(span, action), TIMING), references = all_matches(paste(span, action), REFS),
    stringsAsFactors = FALSE)
}

extract <- function(units) {
  units <- units[units$type != "recital" & !grepl("^art3\\.pt_", units$path) & nzchar(units$text), ]
  by_id <- split(seq_len(nrow(units)), units$unit_id)
  get <- function(id) if (!is.na(id) && !is.null(by_id[[id]])) units[by_id[[id]], ] else NULL
  out <- list()
  for (i in seq_len(nrow(units))) {
    u <- units[i, ]
    sents <- split_sentences(u$text)
    found <- FALSE
    for (k in seq_len(nrow(sents))) {
      s <- sents$sentence[k]
      a <- analyse(s)
      if (is.null(a)) next
      found <- TRUE
      # An introduction to a list ("Providers shall:") is recorded through its points.
      if (grepl(":\\s*(\\[…\\])?$", s) && nchar(a$action) < 200 && u$unit_id %in% units$parent_id) next
      out[[length(out) + 1]] <- record(u, s, sents$start[k], sents$end[k], a)
    }
    # List item without its own modal: take addressee and modal from the
    # nearest introduction ending in ":" (one level up only).
    if (!found && u$type == "point") {
      p <- get(u$parent_id)
      if (!is.null(p) && grepl(":\\s*(\\[…\\])?$|:\\s*\\[…\\]", p$text)) {
        ps <- split_sentences(p$text)
        intro <- ps$sentence[grep(":", ps$sentence)[1]]
        a <- if (!is.na(intro)) analyse(intro) else NULL
        if (!is.null(a)) {
          act <- paste(sub(":.*$", "", a$action), "—", u$text)
          out[[length(out) + 1]] <- record(u, u$text, 1L, nchar(u$text), a, chapeau_id = p$unit_id, action = act)
        }
      }
    }
  }
  ob <- do.call(rbind, out)
  resolve_pronouns(ob, units)
}

# A pronoun subject takes the actor of the closest earlier statement in the
# same unit, else in the parent unit, else earlier in the same article.
resolve_pronouns <- function(ob, units) {
  parent <- setNames(units$parent_id, units$unit_id)
  # "It shall be ensured that ..." has no referent
  expletive <- grepl("^be \\w+ed that\\b|^be (possible|necessary)\\b", tolower(ob$action))
  hit <- which(ob$primary_actor == "unspecified" & !expletive &
               grepl(PRONOUN, tolower(trimws(ob$addressee_text))))
  for (i in hit) {
    earlier <- seq_len(i - 1)
    named <- earlier[ob$actor_basis[earlier] %in% c("subject", "clause")]
    scope <- list(named[ob$unit_id[named] == ob$unit_id[i]],
                  named[ob$unit_id[named] %in% parent[[ob$unit_id[i]]]],
                  named[!is.na(ob$article[named]) & ob$article[named] %in% ob$article[i]])
    for (cand in scope) if (length(cand)) {
      j <- max(cand)
      ob$actors[i] <- ob$actors[j]; ob$primary_actor[i] <- ob$primary_actor[j]
      ob$actor_basis[i] <- "pronoun"
      break
    }
  }
  ob
}

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
for (celex in targets) {
  units <- jsonlite::stream_in(file(file.path(in_dir, paste0(celex, ".jsonl"))), verbose = FALSE)
  CURRENT_CELEX <- celex
  ob <- extract(units)
  ob$obligation_id <- paste0(ob$unit_id, "#", ave(seq_len(nrow(ob)), ob$unit_id, FUN = seq_along))
  ob$celex <- celex
  ob$version <- units$version[1]
  ob$applies_from <- if (celex == "32024R1689") applies_from(ob$article, ob$division) else NA_character_
  # Proposal -> final alignment, when this text is the newer side of one
  af <- list.files(align_dir, paste0("__", celex, "\\.jsonl$"), full.names = TRUE)
  ob$delta_status <- NA; ob$delta_old_id <- NA; ob$delta_score <- NA; ob$delta_confidence <- NA
  if (length(af)) {
    al <- jsonlite::stream_in(file(af[1]), verbose = FALSE)
    j <- match(ob$unit_id, al$new_id)
    ob$delta_status <- al$status[j]; ob$delta_old_id <- al$old_id[j]
    ob$delta_score <- al$score[j]; ob$delta_confidence <- al$confidence[j]
  }
  ob$method <- "rules_v1"
  ob <- ob[, c("obligation_id", "celex", "version", "unit_id", "chapeau_id", "article", "division",
               "span", "span_start", "span_end", "statement_type", "modal", "addressee_text", "actors",
               "primary_actor", "actor_basis", "public_sector", "condition", "action", "timing", "applies_from",
               "references", "delta_status", "delta_old_id", "delta_score", "delta_confidence", "method")]
  f <- file.path(out_dir, paste0(celex, ".jsonl"))
  con <- file(f, open = "w", encoding = "UTF-8")
  jsonlite::stream_out(ob, con, na = "null", verbose = FALSE)
  close(con)

  cat("\n==", celex, ":", nrow(ob), "statements ==\n")
  print(table(ob$statement_type))
  duties <- ob[ob$statement_type %in% c("duty", "prohibition"), ]
  cat("\nDuties and prohibitions by primary actor:\n")
  print(sort(table(duties$primary_actor), decreasing = TRUE))
  if (!all(is.na(ob$delta_status))) {
    cat("\nDuties and prohibitions by proposal -> final status:\n")
    print(table(duties$delta_status, useNA = "ifany"))
  }
  cat("\nActor basis (duties and prohibitions):\n"); print(table(duties$actor_basis))
  d <- duties[grepl("deployer", duties$actors), ]
  cat("Duties/prohibitions naming deployers:", nrow(d),
      "| added since proposal:", sum(d$delta_status %in% "added"),
      "| public-sector specific:", sum(d$public_sector), "\n")
  message("Wrote ", f)
}
