# Align the provision units of two versions of a text (e.g. the 2021 proposal
# and the final AI Act) and classify every unit of the newer version.
#
# Method (deterministic, no LLM):
#   1. Containers (articles and annexes) are matched one-to-one on the
#      similarity of their full text and heading.
#   2. Text units (recitals, paragraphs, subparagraphs, points, annex items) are
#      matched one-to-one on the similarity of their own text, with a bonus when
#      their containers were matched to each other in step 1. The bonus also
#      lowers the threshold, but only for units at the same position inside
#      matched containers.
#   3. Newer units left without a partner are compared again against all older
#      units, including already-matched ones, to catch splits and merges.
# Similarity is TF-IDF cosine over word unigrams and bigrams, after mapping
# terms that were renamed between versions (RENAMES below).
#
# Status of each unit of the newer version:
#   unchanged    identical text after normalisation
#   minor_edit   matched, similarity >= MINOR
#   modified     matched, MATCH <= similarity < MINOR
#   split_merge  no one-to-one partner, but an older unit with similarity >= MATCH
#   added        no older unit with similarity >= MATCH
# Older units without a partner and without any newer unit >= MATCH: deleted.
#
# Output (data/processed/alignment/<OLD>__<NEW>.jsonl), one row per unit:
#   new_id, old_id, status, score (similarity), confidence (high >= 0.6 or
#   identical, medium >= 0.45, low otherwise), container_match (TRUE when the
#   two units sit in containers that were matched in step 1), new_container,
#   old_container, type, new_text, old_text
# plus <OLD>__<NEW>_containers.csv with the step-1 container matches.
#
# Usage from the project root:
#   Rscript scripts/align_versions.R 52021PC0206 32024R1689

library(Matrix)

args <- commandArgs(trailingOnly = TRUE)
old_celex <- if (length(args) >= 2) args[1] else "52021PC0206"
new_celex <- if (length(args) >= 2) args[2] else "32024R1689"
in_dir  <- file.path("data", "processed", "provisions")
out_dir <- file.path("data", "processed", "alignment")

MATCH     <- 0.35   # minimum similarity for a match
MINOR     <- 0.90   # at or above: minor edit
CONTAINER <- 0.30   # minimum similarity for a container match
BONUS     <- 0.10   # added to unit similarity when containers are matched

# Defined terms renamed between proposal and final text, applied to the older
# text before comparison so a rename alone does not lower similarity.
RENAMES <- c("\\busers\\b" = "deployers", "\\buser\\b" = "deployer",
             "\\busers’\\b" = "deployers’", "\\buser’s\\b" = "deployer’s")

read_units <- function(celex) {
  df <- jsonlite::stream_in(file(file.path(in_dir, paste0(celex, ".jsonl"))), verbose = FALSE)
  df$container <- ifelse(!is.na(df$article), paste0("art", df$article),
                  ifelse(grepl("^anx", df$division), sub("\\..*$", "", df$division), NA))
  df$group <- ifelse(df$type == "recital", "recital", "body")
  df
}

normalise <- function(x, renames = NULL) {
  x <- tolower(x)
  for (p in names(renames)) x <- gsub(p, renames[[p]], x, perl = TRUE)
  x <- gsub("[^a-z0-9’' ]+", " ", x)
  gsub("\\s+", " ", trimws(x))
}

# Row-normalised TF-IDF matrices for two text vectors over a shared vocabulary.
tfidf_pair <- function(a, b) {
  toks <- function(s) {
    w <- strsplit(s, " ", fixed = TRUE)
    lapply(w, function(v) c(v, if (length(v) > 1) paste(v[-length(v)], v[-1])))
  }
  ta <- toks(a); tb <- toks(b)
  vocab <- unique(unlist(c(ta, tb)))
  build <- function(t) {
    i <- rep(seq_along(t), lengths(t))
    j <- match(unlist(t), vocab)
    sparseMatrix(i = i, j = j, x = 1, dims = c(length(t), length(vocab)))
  }
  A <- build(ta); B <- build(tb)
  df <- colSums(rbind(A, B) > 0)
  idf <- log((nrow(A) + nrow(B) + 1) / (df + 1)) + 1
  scale_rows <- function(M) {
    M <- M %*% Diagonal(x = idf)
    n <- sqrt(rowSums(M^2)); n[n == 0] <- 1
    Diagonal(x = 1 / n) %*% M
  }
  list(A = scale_rows(A), B = scale_rows(B))
}

cosine <- function(a, b) {
  m <- tfidf_pair(a, b)
  as.matrix(tcrossprod(m$B, m$A))   # rows = newer, columns = older
}

# Greedy one-to-one assignment on a score matrix (rows newer, columns older).
greedy <- function(S, threshold) {
  idx <- which(S >= threshold, arr.ind = TRUE)
  if (!nrow(idx)) return(data.frame(row = integer(), col = integer(), score = numeric()))
  idx <- idx[order(-S[idx]), , drop = FALSE]
  used_r <- logical(nrow(S)); used_c <- logical(ncol(S)); keep <- logical(nrow(idx))
  for (k in seq_len(nrow(idx))) {
    r <- idx[k, 1]; c <- idx[k, 2]
    if (!used_r[r] && !used_c[c]) { keep[k] <- TRUE; used_r[r] <- TRUE; used_c[c] <- TRUE }
  }
  idx <- idx[keep, , drop = FALSE]
  data.frame(row = idx[, 1], col = idx[, 2], score = S[idx])
}

old <- read_units(old_celex)
new <- read_units(new_celex)

# --- 1. Containers ------------------------------------------------------------------

containers <- function(df) {
  top <- df[df$type %in% c("article", "annex"), ]
  data.frame(container = ifelse(top$type == "article", paste0("art", top$label), paste0("anx", top$label)),
             heading = ifelse(is.na(top$heading), "", top$heading),
             text = top$full_text, stringsAsFactors = FALSE)
}
co <- containers(old); cn <- containers(new)
S_body <- cosine(normalise(co$text, RENAMES), normalise(cn$text))
S_head <- cosine(normalise(co$heading, RENAMES), normalise(cn$heading))
S_cont <- 0.8 * S_body + 0.2 * S_head
cm <- greedy(S_cont, CONTAINER)
container_map <- setNames(co$container[cm$col], cn$container[cm$row])   # new -> old
cont_out <- data.frame(new_container = cn$container[cm$row], new_heading = cn$heading[cm$row],
                       old_container = co$container[cm$col], old_heading = co$heading[cm$col],
                       score = round(cm$score, 3))
cont_out <- cont_out[order(as.integer(sub("\\D+", "", cont_out$new_container)),
                           cont_out$new_container), ]

# --- 2 and 3. Text units, per group (recitals / body) ---------------------------------------

align_group <- function(g) {
  o <- old[old$group == g & nzchar(old$text), ]
  n <- new[new$group == g & nzchar(new$text), ]
  S <- cosine(normalise(o$text, RENAMES), normalise(n$text))
  if (g == "body") {
    same <- outer(n$container, o$container, function(a, b) {
      m <- container_map[a]; !is.na(m) & !is.na(b) & m == b
    })
  } else {
    same <- matrix(FALSE, nrow(n), nrow(o))
  }
  # A raw score below MATCH is acceptable only for units with the same own
  # number in matched containers, e.g. a short point (d) that was reworded but
  # kept its place. Unacceptable pairs are removed before assignment so they
  # cannot use up a partner.
  own_num <- function(df) sub("^.*\\.", "", sub("\\.sub[0-9]+$", "", df$path))
  same_pos <- same & outer(own_num(n), own_num(o), "==")
  ok <- S >= MATCH | (same_pos & S >= MATCH - BONUS)
  # The bonus helps choose between candidates; the reported score is the raw one.
  S_adj <- ifelse(ok, pmax(S + BONUS * same, MATCH), 0)
  m <- greedy(S_adj, MATCH)
  res <- data.frame(new_id = n$unit_id, old_id = NA_character_, score = NA_real_,
                    container_match = NA, status = "added", stringsAsFactors = FALSE)
  res$old_id[m$row] <- o$unit_id[m$col]
  res$score[m$row]  <- S[cbind(m$row, m$col)]
  res$container_match[m$row] <- same[cbind(m$row, m$col)]
  ident <- normalise(n$text[m$row]) == normalise(o$text[m$col], RENAMES)
  res$status[m$row] <- ifelse(ident, "unchanged", ifelse(res$score[m$row] >= MINOR, "minor_edit", "modified"))
  # Splits and merges: unmatched newer units with a strong older counterpart
  un <- which(is.na(res$old_id))
  if (length(un)) {
    best <- apply(S[un, , drop = FALSE], 1, which.max)
    sc <- S[cbind(un, best)]
    hit <- sc >= MATCH
    res$old_id[un[hit]] <- o$unit_id[best[hit]]
    res$score[un[hit]] <- sc[hit]
    res$container_match[un[hit]] <- same[cbind(un[hit], best[hit])]
    res$status[un[hit]] <- "split_merge"
  }
  # Deleted: older units with no partner and no newer unit above the threshold
  matched_old <- unique(na.omit(res$old_id))
  gone <- which(!(o$unit_id %in% matched_old) & apply(S, 2, max) < MATCH)
  del <- data.frame(new_id = NA_character_, old_id = o$unit_id[gone],
                    score = if (length(gone)) apply(S[, gone, drop = FALSE], 2, max) else numeric(),
                    container_match = NA, status = rep("deleted", length(gone)), stringsAsFactors = FALSE)
  rbind(res, del)
}

al <- rbind(align_group("recital"), align_group("body"))
al$score <- round(al$score, 3)
# How much to trust a pairing; low-confidence pairs are candidates for review.
al$confidence <- ifelse(al$status %in% c("added", "deleted"), NA,
                 ifelse(al$status == "unchanged" | al$score >= 0.6, "high",
                 ifelse(al$score >= 0.45, "medium", "low")))
lookup <- function(df, ids, col) df[[col]][match(ids, df$unit_id)]
al$type <- ifelse(is.na(al$new_id), lookup(old, al$old_id, "type"), lookup(new, al$new_id, "type"))
al$new_container <- lookup(new, al$new_id, "container")
al$old_container <- lookup(old, al$old_id, "container")
al$new_text <- lookup(new, al$new_id, "text")
al$old_text <- lookup(old, al$old_id, "text")
al$new_seq <- lookup(new, al$new_id, "seq")
al <- al[order(is.na(al$new_seq), al$new_seq), ]
al$new_seq <- NULL
al <- al[, c("new_id", "old_id", "status", "score", "confidence", "container_match", "type",
             "new_container", "old_container", "new_text", "old_text")]

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
base <- file.path(out_dir, paste0(old_celex, "__", new_celex))
con <- file(paste0(base, ".jsonl"), open = "w", encoding = "UTF-8")
jsonlite::stream_out(al, con, na = "null", verbose = FALSE)
close(con)
write.csv(cont_out, paste0(base, "_containers.csv"), row.names = FALSE, fileEncoding = "UTF-8")

# --- Summary ----------------------------------------------------------------------------

cat("Containers matched:", nrow(cm), "of", nrow(cn), "new /", nrow(co), "old\n")
cat("\nStatus by group:\n")
print(table(ifelse(al$type == "recital", "recital", "body"), factor(al$status,
      c("unchanged", "minor_edit", "modified", "split_merge", "added", "deleted"))))
body_new <- al[!is.na(al$new_id) & al$type != "recital", ]
by_art <- tapply(body_new$status == "added", body_new$new_container, mean)
n_art <- table(body_new$new_container)
all_new <- names(by_art)[by_art == 1]
cat("\nNew containers with every unit added (", length(all_new), "):",
    paste(all_new[order(as.integer(sub("\\D+", "", all_new)))], collapse = " "), "\n")
message("Wrote ", base, ".jsonl and ", base, "_containers.csv")
