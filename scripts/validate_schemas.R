# Validate every pipeline file against the schemas in docs/schemas/.
#
# Each check is PASS, WARN (allowed, worth a look) or FAIL (breaks a rule in
# the documents). Results are printed and written to
# docs/schemas/validation-report.md. Exit status 1 when any check fails.
#
# The field specs below mirror the tables in docs/schemas/0*.md; when a
# document changes, change the spec here in the same commit.
#
# Usage from the project root:  Rscript scripts/validate_schemas.R

options(warn = 1)
report_file <- file.path("docs", "schemas", "validation-report.md")

# --- Result collection ----------------------------------------------------------------

results <- data.frame(layer = character(), dataset = character(), check = character(),
                      status = character(), detail = character(), stringsAsFactors = FALSE)
add <- function(layer, dataset, check, status, detail = "") {
  results[nrow(results) + 1, ] <<- list(layer, dataset, check, status, detail)
}
# ok: TRUE/FALSE; bad: offending values, shown when the check does not pass
chk <- function(layer, dataset, check, ok, bad = character(), warn = FALSE, note = "") {
  status <- if (isTRUE(ok)) "PASS" else if (warn) "WARN" else "FAIL"
  detail <- if (isTRUE(ok)) note else {
    bad <- unique(as.character(bad))
    paste0(length(bad), " offending: ", paste(head(bad, 5), collapse = "; "),
           if (length(bad) > 5) "; …" else "")
  }
  add(layer, dataset, check, status, detail)
  invisible(ok)
}
guard <- function(layer, dataset, expr) {
  tryCatch(expr, error = function(e) add(layer, dataset, "check ran", "FAIL", conditionMessage(e)))
}

# --- Readers ------------------------------------------------------------------------

read_jsonl <- function(f) jsonlite::stream_in(file(f), verbose = FALSE)
read_csv_text <- function(f) read.csv(f, colClasses = "character", na.strings = character(),
                                      encoding = "UTF-8", fileEncoding = "UTF-8-BOM", check.names = FALSE)
read_csv_typed <- function(f, ...) read.csv(f, stringsAsFactors = FALSE, na.strings = c("", "NA"),
                                            encoding = "UTF-8", fileEncoding = "UTF-8-BOM", check.names = FALSE, ...)
# Key sets of each JSON line, to check that a row has exactly its documented fields
line_keys <- function(f) lapply(readLines(f, encoding = "UTF-8", warn = FALSE),
                                function(l) names(jsonlite::fromJSON(l, simplifyVector = FALSE)))
md5 <- function(f) unname(tools::md5sum(f))
empty <- function(v) is.na(v) | (is.character(v) & !nzchar(v))

# --- Field specs --------------------------------------------------------------------
# f(type, required, enum, pattern); required: "yes", "empty_ok" or "no"

f <- function(type, required = "yes", enum = NULL, pattern = NULL)
  list(type = type, required = required, enum = enum, pattern = pattern)
RX <- list(
  celex = "^[0-9]{5}[A-Z]{1,2}[0-9]{4}$",
  unit = "^[0-9]{5}[A-Z]{1,2}[0-9]{4}:[A-Za-z0-9_.-]+$",
  date = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
  gm = "^GM[0-9]{4}$"
)
CONF <- c("high", "medium", "low")
UNIT_TYPES <- c("recital", "title", "chapter", "section", "article", "paragraph", "subparagraph",
                "point", "annex", "annex_section")
STATUS <- c("unchanged", "minor_edit", "modified", "split_merge", "added", "deleted")
ACTORS <- c("gpai_provider", "deployer", "provider", "importer", "distributor", "authorised_representative",
            "product_manufacturer", "operator", "notified_body", "notifying_authority",
            "market_surveillance_authority", "national_competent_authority", "member_state", "commission",
            "ai_office", "board", "scientific_panel", "advisory_forum", "edps", "union_institutions",
            "public_authority")

check_fields <- function(layer, dataset, df, spec, keys = NULL) {
  present <- if (is.null(keys)) names(df) else unique(unlist(keys))
  chk(layer, dataset, "all documented fields present", all(names(spec) %in% present), setdiff(names(spec), present))
  chk(layer, dataset, "no undocumented fields", all(present %in% names(spec)), setdiff(present, names(spec)))
  for (nm in intersect(names(spec), names(df))) {
    s <- spec[[nm]]; v <- df[[nm]]; nn <- v[!is.na(v)]
    type_ok <- switch(s$type,
      string = is.character(nn) || !length(nn),
      integer = (is.numeric(nn) && all(nn == round(nn))) || !length(nn),
      number = is.numeric(nn) || !length(nn),
      boolean = is.logical(nn) || !length(nn),
      date = (is.character(nn) && all(grepl(RX$date, nn))) || !length(nn))
    chk(layer, dataset, sprintf("`%s` has type %s", nm, s$type), type_ok, head(nn, 5))
    if (s$required == "yes") chk(layer, dataset, sprintf("`%s` required", nm), !any(empty(v)), which(empty(v)))
    if (s$required == "empty_ok") chk(layer, dataset, sprintf("`%s` never null", nm), !any(is.na(v)), which(is.na(v)))
    if (!is.null(s$enum)) chk(layer, dataset, sprintf("`%s` allowed values", nm), all(nn %in% s$enum), setdiff(nn, s$enum))
    if (!is.null(s$pattern)) chk(layer, dataset, sprintf("`%s` matches pattern", nm),
                                 all(grepl(s$pattern, nn, perl = TRUE)), nn[!grepl(s$pattern, nn, perl = TRUE)])
  }
}

# ===================================================================================
# Layer 1: raw sources
# ===================================================================================

L <- "1 raw"
guard(L, "ai_act", {
  d <- file.path("data", "raw", "ai_act"); m <- jsonlite::read_json(file.path(d, "32024R1689_manifest.json"))
  files <- c(list(m$notice), list(m$fmx4$zip), m$fmx4$files)
  paths <- vapply(files, function(x) if (grepl("fmx\\.xml$", x$file)) file.path(d, "fmx4", x$file) else file.path(d, x$file), "")
  ok <- file.exists(paths) & vapply(seq_along(paths), function(i) file.exists(paths[i]) && md5(paths[i]) == files[[i]]$md5, TRUE)
  chk(L, "ai_act", "manifest checksums match files", all(ok), basename(paths[!ok]))
  roots <- vapply(m$fmx4$files, function(x) x$root, "")
  chk(L, "ai_act", "one ACT file and 13 ANNEX files", sum(roots == "ACT") == 1 && sum(roots == "ANNEX") == 13,
      paste(names(table(roots)), table(roots)))
  for (fmt in c("fmx4", "xhtml")) chk(L, "ai_act", paste("counts match expected,", fmt),
      all(unlist(m[[fmt]]$counts_match_expected)), names(which(!unlist(m[[fmt]]$counts_match_expected))))
})
for (pd in list.dirs(file.path("data", "raw", "proposals"), recursive = FALSE)) guard(L, basename(pd), {
  m <- jsonlite::read_json(list.files(pd, "_manifest\\.json$", full.names = TRUE))
  ok <- vapply(m$items, function(x) { p <- file.path(pd, x$file); file.exists(p) && md5(p) == x$md5 }, TRUE)
  chk(L, paste0("proposal ", basename(pd)), "manifest checksums match files", all(ok),
      vapply(m$items[!ok], function(x) x$file, ""))
})
guard(L, "algorithm_register", {
  d <- file.path("data", "raw", "algorithm_register"); m <- jsonlite::read_json(file.path(d, "algoritmeregister_manifest.json"))
  used <- c("algorithm_id", "organization", "org_id", "name", "description_short", "goal", "category", "status",
            "publication_category", "provider", "impacttoetsen", "impacttoetsen_grouping", "human_intervention",
            "risks", "methods_and_models", "source_data", "lawful_basis", "begin_date", "end_date", "publication_dt")
  for (part in c("current", "history")) {
    p <- file.path(d, m[[part]]$file)
    chk(L, "algorithm_register", paste("checksum matches,", part), md5(p) == m[[part]]$md5, m[[part]]$file)
    df <- read_csv_typed(p)
    chk(L, "algorithm_register", paste("row count matches manifest,", part), nrow(df) == m[[part]]$n_rows,
        paste(nrow(df), "vs", m[[part]]$n_rows))
    need <- if (part == "history") c(used, "department") else used
    chk(L, "algorithm_register", paste("used columns present,", part), all(need %in% names(df)), setdiff(need, names(df)))
    if (part == "current") {
      reg_current <- df
      chk(L, "algorithm_register", "`algorithm_id` unique in current file", !anyDuplicated(df$algorithm_id),
          df$algorithm_id[duplicated(df$algorithm_id)])
    }
  }
})
guard(L, "cbs_iv3", {
  d <- file.path("data", "raw", "cbs_iv3")
  dims <- list()
  for (nm in c("taakveld", "categorie", "verslagsoort", "gemeenten")) {
    x <- read_csv_text(file.path(d, paste0("dim_", nm, ".csv")))
    check_fields(L, paste0("dim_", nm), x, list(Key = f("string"), Title = f("string"), Description = f("string", "no")))
    chk(L, paste0("dim_", nm), "`Key` unique", !anyDuplicated(x$Key), x$Key[duplicated(x$Key)])
    dims[[nm]] <- x
  }
  iv3 <- read_csv_typed(file.path(d, "iv3_2025.csv"), colClasses = c(TaakveldBalanspost = "character"))
  check_fields(L, "iv3_2025", iv3, list(
    ID = f("integer"), TaakveldBalanspost = f("string"), Categorie = f("string"),
    Gemeenten = f("string", enum = c("GM0363", "GM0518", "GM0715")),
    Verslagsoort = f("string", enum = c("2025X000", "2025X005")),
    release1_keur = f("integer", "no"), release2_keur = f("integer", "no")))
  chk(L, "iv3_2025", "`ID` unique", !anyDuplicated(iv3$ID), iv3$ID[duplicated(iv3$ID)])
  k <- paste(iv3$TaakveldBalanspost, iv3$Categorie, iv3$Gemeenten, iv3$Verslagsoort)
  chk(L, "iv3_2025", "row key unique", !anyDuplicated(k), k[duplicated(k)])
  chk(L, "iv3_2025", "task fields exist in dim_taakveld", all(iv3$TaakveldBalanspost %in% dims$taakveld$Key),
      setdiff(iv3$TaakveldBalanspost, dims$taakveld$Key))
  chk(L, "iv3_2025", "categories exist in dim_categorie", all(iv3$Categorie %in% dims$categorie$Key),
      setdiff(iv3$Categorie, dims$categorie$Key))
  combos <- table(iv3$Gemeenten, iv3$Verslagsoort)
  chk(L, "iv3_2025", "every municipality × report has rows", all(dim(combos) == c(3, 2)) && all(combos > 0),
      paste(rownames(combos)[row(combos)[combos == 0]], colnames(combos)[col(combos)[combos == 0]]))
  m <- jsonlite::read_json(file.path(d, "iv3_2025_manifest.json"))
  chk(L, "iv3_2025", "row count matches manifest", nrow(iv3) == m$n_rows, paste(nrow(iv3), "vs", m$n_rows))
})

# ===================================================================================
# Layer 2: provision units
# ===================================================================================

L <- "2 provisions"
EXPECTED <- list("32024R1689" = c(recitals = 180, articles = 113, annexes = 13, definitions = 68),
                 "52021PC0206" = c(recitals = 89, articles = 85, annexes = 9, definitions = 44))
prov <- list()
for (fp in list.files(file.path("data", "processed", "provisions"), "\\.jsonl$", full.names = TRUE)) {
  celex <- sub("\\.jsonl$", "", basename(fp)); ds <- basename(fp)
  guard(L, ds, {
    u <- read_jsonl(fp); prov[[celex]] <- u
    check_fields(L, ds, u, list(
      unit_id = f("string", pattern = RX$unit), celex = f("string", pattern = RX$celex),
      version = f("string", enum = c("final_2024", "proposal_2021")), seq = f("integer"),
      type = f("string", enum = UNIT_TYPES), path = f("string"), parent_id = f("string", "no", pattern = RX$unit),
      depth = f("integer"), num = f("string", "no"), label = f("string"), heading = f("string", "no"),
      text = f("string", "empty_ok"), full_text = f("string"), division = f("string", "no"),
      article = f("string", "no"), source_file = f("string"), source_ref = f("string", "no"),
      notes = f("string", "no")))
    chk(L, ds, "`unit_id` unique", !anyDuplicated(u$unit_id), u$unit_id[duplicated(u$unit_id)])
    chk(L, ds, "`unit_id` = celex:path", all(u$unit_id == paste0(u$celex, ":", u$path)), u$unit_id[u$unit_id != paste0(u$celex, ":", u$path)])
    chk(L, ds, "`celex` matches file name", all(u$celex == celex), unique(u$celex))
    chk(L, ds, "`seq` runs 1..n", identical(as.integer(u$seq), seq_len(nrow(u))), "")
    pi <- match(u$parent_id, u$unit_id)
    chk(L, ds, "parents exist", all(is.na(u$parent_id) | !is.na(pi)), u$parent_id[!is.na(u$parent_id) & is.na(pi)])
    chk(L, ds, "parents come first", all(is.na(pi) | u$seq[pi] < u$seq), u$unit_id[!is.na(pi) & u$seq[pi] >= u$seq])
    exp_depth <- ifelse(is.na(pi), 0, u$depth[pi] + 1)
    chk(L, ds, "`depth` = parent depth + 1", all(u$depth == exp_depth), u$unit_id[u$depth != exp_depth])
    tp <- list(recital = "^rct[0-9]+$", article = "^art[0-9]+$", annex = "^anx[IVXLC]+$")
    for (t in names(tp)) { x <- u[u$type == t, ]
      chk(L, ds, paste("path pattern for", t), all(grepl(tp[[t]], x$path)), x$path[!grepl(tp[[t]], x$path)]) }
    art_exp <- ifelse(u$type == "article", u$label, ifelse(is.na(pi), NA, u$article[pi]))
    bad <- !(is.na(art_exp) & is.na(u$article)) & (is.na(art_exp) | is.na(u$article) | art_exp != u$article)
    chk(L, ds, "`article` inherited from the article", !any(bad), u$unit_id[bad])
    contains <- mapply(function(t, ft) grepl(t, ft, fixed = TRUE), u$text, u$full_text)
    chk(L, ds, "`full_text` contains `text`", all(contains), u$unit_id[!contains])
    e <- EXPECTED[[celex]]
    if (!is.null(e)) {
      arts <- sort(as.integer(u$label[u$type == "article"]))
      got <- c(recitals = sum(u$type == "recital"), articles = length(arts), annexes = sum(u$type == "annex"),
               definitions = sum(u$parent_id %in% paste0(celex, ":art3") & u$type == "point"))
      chk(L, ds, "counts match the published document", all(got == e) && identical(arts, seq_len(e[["articles"]])),
          paste(names(e), got, "vs", e)[got != e])
    }
    chk(L, ds, "no duplicate-path units", !any(grepl("_dup[0-9]+$", u$path)), u$path[grepl("_dup[0-9]+$", u$path)], warn = TRUE)
  })
}

# ===================================================================================
# Layer 3: alignment
# ===================================================================================

L <- "3 alignment"
alig <- list()
for (fa in list.files(file.path("data", "processed", "alignment"), "__.*\\.jsonl$", full.names = TRUE)) {
  ds <- basename(fa); pair <- strsplit(sub("\\.jsonl$", "", ds), "__")[[1]]
  guard(L, ds, {
    a <- read_jsonl(fa); alig[[pair[2]]] <- a
    old <- prov[[pair[1]]]; new <- prov[[pair[2]]]
    check_fields(L, ds, a, list(
      new_id = f("string", "no", pattern = RX$unit), old_id = f("string", "no", pattern = RX$unit),
      status = f("string", enum = STATUS), score = f("number", "no"), confidence = f("string", "no", enum = CONF),
      container_match = f("boolean", "no"), type = f("string", enum = UNIT_TYPES),
      new_container = f("string", "no"), old_container = f("string", "no"),
      new_text = f("string", "no"), old_text = f("string", "no")))
    chk(L, ds, "`new_id` exists in newer provisions", all(is.na(a$new_id) | a$new_id %in% new$unit_id), setdiff(na.omit(a$new_id), new$unit_id))
    chk(L, ds, "`old_id` exists in older provisions", all(is.na(a$old_id) | a$old_id %in% old$unit_id), setdiff(na.omit(a$old_id), old$unit_id))
    nid <- na.omit(a$new_id)
    chk(L, ds, "each `new_id` once", !anyDuplicated(nid), nid[duplicated(nid)])
    o2o <- a$old_id[a$status %in% c("unchanged", "minor_edit", "modified")]
    chk(L, ds, "one-to-one `old_id` used once", !anyDuplicated(o2o), o2o[duplicated(o2o)])
    with_text <- new$unit_id[nzchar(new$text)]
    chk(L, ds, "every newer unit with text has a row", setequal(with_text, nid), c(setdiff(with_text, nid), setdiff(nid, with_text)))
    s <- a$status; set <- function(x) !is.na(x)
    pattern_ok <- ifelse(s == "added", set(a$new_id) & !set(a$old_id) & !set(a$score),
                  ifelse(s == "deleted", !set(a$new_id) & set(a$old_id) & set(a$score) & a$score < 0.35,
                  ifelse(s == "minor_edit", set(a$new_id) & set(a$old_id) & a$score >= 0.9,
                  ifelse(s == "modified", set(a$new_id) & set(a$old_id) & a$score < 0.9 & a$score >= 0.25,
                  ifelse(s == "split_merge", set(a$new_id) & set(a$old_id) & a$score >= 0.35,
                         set(a$new_id) & set(a$old_id) & set(a$score))))))
    chk(L, ds, "ids and score fit the status", all(pattern_ok %in% TRUE), paste(s, a$new_id, a$old_id)[!(pattern_ok %in% TRUE)])
    no_conf <- s %in% c("added", "deleted")
    chk(L, ds, "`confidence` null exactly for added/deleted", all(is.na(a$confidence) == no_conf), paste(s, a$new_id)[is.na(a$confidence) != no_conf])
    nt <- new$text[match(a$new_id, new$unit_id)]; ot <- old$text[match(a$old_id, old$unit_id)]
    bad_n <- !is.na(a$new_id) & !((nt == a$new_text) %in% TRUE); bad_o <- !is.na(a$old_id) & !((ot == a$old_text) %in% TRUE)
    chk(L, ds, "texts equal the referenced units", !any(bad_n | bad_o), c(a$new_id[bad_n], a$old_id[bad_o]))
    fc <- sub("\\.jsonl$", "_containers.csv", fa)
    co <- read_csv_typed(fc)
    check_fields(L, basename(fc), co, list(new_container = f("string"), new_heading = f("string", "no"),
      old_container = f("string"), old_heading = f("string", "no"), score = f("number")))
    chk(L, basename(fc), "container pairs one-to-one", !anyDuplicated(co$new_container) && !anyDuplicated(co$old_container), "")
    cont <- function(u) ifelse(u$type == "article", paste0("art", u$label), paste0("anx", u$label))[u$type %in% c("article", "annex")]
    chk(L, basename(fc), "containers exist", all(co$new_container %in% cont(new)) && all(co$old_container %in% cont(old)),
        c(setdiff(co$new_container, cont(new)), setdiff(co$old_container, cont(old))))
    chk(L, basename(fc), "`score` ≥ 0.30", all(co$score >= 0.30), co$new_container[co$score < 0.30])
  })
}

# ===================================================================================
# Layer 4: obligations
# ===================================================================================

L <- "4 obligations"
for (fo in list.files(file.path("data", "processed", "obligations"), "\\.jsonl$", full.names = TRUE)) {
  celex <- sub("\\.jsonl$", "", basename(fo)); ds <- basename(fo)
  guard(L, ds, {
    o <- read_jsonl(fo); u <- prov[[celex]]
    check_fields(L, ds, o, list(
      obligation_id = f("string", pattern = "#[0-9]+$"), celex = f("string", pattern = RX$celex),
      version = f("string", enum = c("final_2024", "proposal_2021")), unit_id = f("string", pattern = RX$unit),
      chapeau_id = f("string", "no", pattern = RX$unit), article = f("string", "no"), division = f("string"),
      span = f("string"), span_start = f("integer"), span_end = f("integer"),
      statement_type = f("string", enum = c("duty", "prohibition", "permission", "power", "applicability", "deeming")),
      modal = f("string", enum = c("shall", "shall not", "must", "must not", "may", "may not", "is prohibited",
                                   "are prohibited", "is required to", "are required to")),
      addressee_text = f("string", "empty_ok"), actors = f("string", "no"),
      primary_actor = f("string", enum = c(ACTORS, "unspecified")),
      actor_basis = f("string", enum = c("subject", "clause", "pronoun", "none")),
      public_sector = f("boolean"), condition = f("string", "no"), action = f("string"),
      timing = f("string", "no"), applies_from = f("date", "no", enum = c("2025-02-02", "2025-08-02", "2026-08-02")),
      references = f("string", "no"), delta_status = f("string", "no", enum = setdiff(STATUS, "deleted")),
      delta_old_id = f("string", "no", pattern = RX$unit), delta_score = f("number", "no"),
      delta_confidence = f("string", "no", enum = CONF), method = f("string", enum = "rules_v1")))
    chk(L, ds, "`obligation_id` unique", !anyDuplicated(o$obligation_id), o$obligation_id[duplicated(o$obligation_id)])
    chk(L, ds, "`obligation_id` starts with unit_id#", all(startsWith(o$obligation_id, paste0(o$unit_id, "#"))), o$obligation_id[!startsWith(o$obligation_id, paste0(o$unit_id, "#"))])
    chk(L, ds, "`unit_id` exists", all(o$unit_id %in% u$unit_id), setdiff(o$unit_id, u$unit_id))
    chk(L, ds, "`chapeau_id` exists", all(is.na(o$chapeau_id) | o$chapeau_id %in% u$unit_id), setdiff(na.omit(o$chapeau_id), u$unit_id))
    ut <- u$text[match(o$unit_id, u$unit_id)]
    sub_ok <- substring(ut, o$span_start, o$span_end) == o$span
    chk(L, ds, "`span` is the text at its offsets", all(sub_ok %in% TRUE), o$obligation_id[!(sub_ok %in% TRUE)])
    lp <- !is.na(o$chapeau_id)
    chk(L, ds, "list points span the whole point", all((o$span == ut)[lp]), o$obligation_id[lp & o$span != ut])
    first_actor <- sub(";.*$", "", o$actors)
    cons <- ifelse(o$actor_basis == "none", o$primary_actor == "unspecified",
                   o$primary_actor != "unspecified" & first_actor == o$primary_actor)
    chk(L, ds, "`primary_actor` consistent with basis and actors", all(cons %in% TRUE), o$obligation_id[!(cons %in% TRUE)])
    acts <- unique(unlist(strsplit(na.omit(o$actors), ";")))
    chk(L, ds, "`actors` are actor categories", all(acts %in% ACTORS), setdiff(acts, ACTORS))
    a <- alig[[celex]]
    if (!is.null(a)) {
      j <- match(o$unit_id, a$new_id)
      chk(L, ds, "every obligation has an alignment row", !anyNA(j), o$unit_id[is.na(j)])
      same <- function(x, y) (is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & x == y)
      eq <- same(o$delta_status, a$status[j]) & same(o$delta_old_id, a$old_id[j]) &
            same(o$delta_score, a$score[j]) & same(o$delta_confidence, a$confidence[j])
      chk(L, ds, "`delta_*` equal the alignment row", all(eq), o$obligation_id[!eq])
      arts <- !is.na(o$article)
      chk(L, ds, "`applies_from` set for every article", all(!is.na(o$applies_from[arts])), o$obligation_id[arts & is.na(o$applies_from)])
    } else {
      dn <- is.na(o$delta_status) & is.na(o$delta_old_id) & is.na(o$delta_score) & is.na(o$delta_confidence) & is.na(o$applies_from)
      chk(L, ds, "older version has no delta or application date", all(dn), o$obligation_id[!dn])
    }
  })
}

# ===================================================================================
# Layer 5: organization graph
# ===================================================================================

L <- "5 org graph"
guard(L, "org_graph", {
  d <- file.path("data", "processed", "org_graph")
  n <- read_jsonl(file.path(d, "nodes.jsonl")); e <- read_jsonl(file.path(d, "edges.jsonl"))
  nk <- line_keys(file.path(d, "nodes.jsonl")); ek <- line_keys(file.path(d, "edges.jsonl"))
  common <- list(id = f("string"), type = f("string", enum = c("municipality", "department", "system", "supplier", "taskfield")),
                 source = f("string", enum = c("register_current", "register_history", "cbs_iv3", "supplier_alias", "supplier_rule")),
                 source_ref = f("string"), confidence = f("string", enum = c(CONF, "unknown")))
  types <- list(
    municipality = list(id = "^GM[0-9]{4}$", fields = list(name = f("string"), register_org_id = f("string"))),
    department = list(id = "^GM[0-9]{4}:dept:[a-z0-9-]+$", fields = list(municipality = f("string", pattern = RX$gm), name = f("string"))),
    system = list(id = "^sys:[0-9]+$", fields = list(
      municipality = f("string", pattern = RX$gm), name = f("string"), description_short = f("string"), goal = f("string"),
      status = f("string", enum = c("In gebruik", "In ontwikkeling", "Buiten gebruik")),
      begin_date = f("string", "no", pattern = "^[0-9]{4}-[0-9]{2}$"), end_date = f("string", "no", pattern = "^[0-9]{4}-[0-9]{2}$"),
      self_category = f("string", enum = c("Hoog-risico AI-systeem", "Impactvolle algoritmes", "Overige algoritmes")),
      themes = f("string", "no"), has_dpia = f("boolean"), has_iama = f("boolean"), assessments_raw = f("string", "no"),
      has_human_oversight_text = f("boolean"), methods_and_models = f("string", "no"), human_intervention = f("string", "no"),
      risks = f("string", "no"), source_data = f("string", "no"), lawful_basis = f("string", "no"),
      provider_raw = f("string", "no"), publication_dt = f("string"), aiact_class = f("string", "no"), aiact_role = f("string", "no"))),
    supplier = list(id = "^(sup:[a-z0-9-]+|GM[0-9]{4}:sup:in-house)$", fields = list(
      name = f("string"), in_house = f("boolean"), n_municipalities = f("integer"))),
    taskfield = list(id = "^GM[0-9]{4}:tf:[0-9]\\.[0-9]+$", fields = list(
      municipality = f("string", pattern = RX$gm), code = f("string"), title = f("string"), is_overhead = f("boolean"),
      budget_2025_keur = f("integer"), actuals_2025_keur = f("integer"), budget_personnel_keur = f("integer"),
      budget_goods_services_keur = f("integer"), actuals_personnel_keur = f("integer"), actuals_goods_services_keur = f("integer"))))
  for (t in names(types)) {
    sel <- n$type == t
    x <- n[sel, , drop = FALSE]; spec <- c(common, types[[t]]$fields); spec$id$pattern <- types[[t]]$id
    check_fields(L, paste("nodes:", t), x[, intersect(names(x), names(spec)), drop = FALSE], spec, keys = nk[sel])
  }
  chk(L, "nodes", "node types known", all(n$type %in% names(types)), setdiff(n$type, names(types)))
  chk(L, "nodes", "`id` unique", !anyDuplicated(n$id), n$id[duplicated(n$id)])

  etypes <- list(operates = c("municipality", "system"), has_department = c("municipality", "department"),
                 runs = c("department", "system"), supplied_by = c("system", "supplier"),
                 funded_from = c("system", "taskfield"), spends_on = c("municipality", "taskfield"),
                 overhead_of = c("taskfield", "municipality"))
  ecommon <- list(from = f("string"), to = f("string"), type = f("string", enum = names(etypes)),
                  source = f("string", enum = c("register_current", "register_history", "cbs_iv3", "fixed", "keyword_rule",
                                               "theme_map", "supplier_alias", "supplier_rule")),
                  source_ref = f("string"), confidence = f("string", enum = c(CONF, "unknown")))
  extra <- list(runs = list(note = f("string")), spends_on = list(budget_2025_keur = f("integer")))
  for (t in names(etypes)) {
    sel <- e$type == t; x <- e[sel, , drop = FALSE]; spec <- c(ecommon, extra[[t]])
    check_fields(L, paste("edges:", t), x[, intersect(names(x), names(spec)), drop = FALSE], spec, keys = ek[sel])
    ft <- n$type[match(x$from, n$id)]; tt <- n$type[match(x$to, n$id)]
    ok <- !is.na(ft) & !is.na(tt) & ft == etypes[[t]][1] & tt == etypes[[t]][2]
    chk(L, paste("edges:", t), "endpoints exist with the right node types", all(ok), paste(x$from, x$to)[!ok])
  }
  chk(L, "edges", "edge types known", all(e$type %in% names(etypes)), setdiff(e$type, names(etypes)))
  ek3 <- paste(e$from, e$to, e$type)
  chk(L, "edges", "no duplicate edges", !anyDuplicated(ek3), ek3[duplicated(ek3)])

  count_to <- function(t, ids, col = "to") as.integer(table(factor(e[[col]][e$type == t], levels = ids)))
  sys_ids <- n$id[n$type == "system"]; dep_ids <- n$id[n$type == "department"]
  tf_ids <- n$id[n$type == "taskfield"]; mun_ids <- n$id[n$type == "municipality"]
  chk(L, "edges", "one `operates` per system", all(count_to("operates", sys_ids) == 1), sys_ids[count_to("operates", sys_ids) != 1])
  chk(L, "edges", "one `has_department` per department", all(count_to("has_department", dep_ids) == 1), dep_ids[count_to("has_department", dep_ids) != 1])
  chk(L, "edges", "at most one `runs` per system", all(count_to("runs", sys_ids) <= 1), sys_ids[count_to("runs", sys_ids) > 1])
  chk(L, "edges", "one `spends_on` per task field", all(count_to("spends_on", tf_ids) == 1), tf_ids[count_to("spends_on", tf_ids) != 1])
  ov <- count_to("overhead_of", mun_ids)
  chk(L, "edges", "one `overhead_of` per municipality, from 0.4", all(ov == 1) && all(grepl(":tf:0\\.4$", e$from[e$type == "overhead_of"])), mun_ids[ov != 1])

  muni <- setNames(ifelse(n$type == "municipality", n$id, n$municipality), n$id)
  same_m <- function(t) { x <- e[e$type == t, ]; ok <- muni[x$from] == muni[x$to]; list(ok = all(ok %in% TRUE), bad = paste(x$from, x$to)[!(ok %in% TRUE)]) }
  for (t in c("operates", "runs", "funded_from", "spends_on", "has_department", "overhead_of")) {
    r <- same_m(t); chk(L, paste("edges:", t), "stays within one municipality", r$ok, r$bad)
  }
  so <- e[e$type == "spends_on", ]
  b_ok <- so$budget_2025_keur == n$budget_2025_keur[match(so$to, n$id)]
  chk(L, "edges: spends_on", "budget equals the task field's budget", all(b_ok %in% TRUE), so$to[!(b_ok %in% TRUE)])

  tf <- n[n$type == "taskfield", ]
  if (exists("iv3")) {
    v <- ifelse(is.na(iv3$release2_keur), iv3$release1_keur, iv3$release2_keur)
    sel <- grepl("^L", iv3$Categorie) & iv3$Categorie != "L7.1"
    recompute <- function(rep, cats = NULL) {
      s <- sel & iv3$Verslagsoort == rep & (if (is.null(cats)) TRUE else iv3$Categorie %in% cats)
      agg <- tapply(v[s], paste0(iv3$Gemeenten[s], ":tf:", iv3$TaakveldBalanspost[s]), sum, na.rm = TRUE)
      r <- as.numeric(agg[tf$id]); r[is.na(r)] <- 0; r
    }
    for (spec in list(list("budget_2025_keur", "2025X000", NULL), list("actuals_2025_keur", "2025X005", NULL),
                      list("budget_personnel_keur", "2025X000", c("L1.1", "L3.5.1")),
                      list("actuals_personnel_keur", "2025X005", c("L1.1", "L3.5.1")),
                      list("budget_goods_services_keur", "2025X000", "L3.8"),
                      list("actuals_goods_services_keur", "2025X005", "L3.8"))) {
      ok <- tf[[spec[[1]]]] == recompute(spec[[2]], spec[[3]])
      chk(L, "nodes: taskfield", paste0("`", spec[[1]], "` equals the Iv3 rows"), all(ok %in% TRUE), tf$id[!(ok %in% TRUE)])
    }
    chk(L, "nodes: taskfield", "`code` exists in dim_taakveld", all(tf$code %in% dims$taakveld$Key), setdiff(tf$code, dims$taakveld$Key))
    chk(L, "nodes: taskfield", "`is_overhead` exactly for 0.4", all(tf$is_overhead == (tf$code == "0.4")), tf$id[tf$is_overhead != (tf$code == "0.4")])
  }
  if (exists("reg_current")) {
    s <- n[n$type == "system", ]
    chk(L, "nodes: system", "`source_ref` is a current register algorithm_id", all(s$source_ref %in% as.character(reg_current$algorithm_id)),
        setdiff(s$source_ref, as.character(reg_current$algorithm_id)))
  }
  sb <- e[e$type == "supplied_by", ]
  real <- tapply(muni[sb$from], sb$to, function(x) length(unique(x)))
  sp <- n[n$type == "supplier", ]
  ok <- sp$n_municipalities == as.integer(real[sp$id])
  chk(L, "nodes: supplier", "`n_municipalities` matches linked systems", all(ok %in% TRUE), sp$id[!(ok %in% TRUE)])
  chk(L, "nodes: supplier", "every supplier has a system", all(sp$id %in% sb$to), setdiff(sp$id, sb$to))
  low <- sb$from[sb$confidence == "low"]
  chk(L, "edges: supplied_by", "all suppliers resolved through the alias table", !length(low),
      n$provider_raw[match(low, n$id)], warn = TRUE)
  nofund <- setdiff(sys_ids, e$from[e$type == "funded_from"])
  chk(L, "edges: funded_from", "every system has a task field", !length(nofund), n$name[match(nofund, n$id)], warn = TRUE)
})

# ===================================================================================
# Reference tables
# ===================================================================================

L <- "ref tables"
guard(L, "reference", {
  d <- file.path("data", "reference")
  tv_title <- function(code) { t <- dims$taakveld$Title[match(code, dims$taakveld$Key)]; sub("^\\S+\\s+", "", t) }
  title_ok <- function(code, title) { cbs <- sub("(\\.\\.|…)$", "", tv_title(code)); !is.na(cbs) & startsWith(title, cbs) }

  tm <- read_csv_text(file.path(d, "theme_to_taakveld.csv"))
  check_fields(L, "theme_to_taakveld", tm, list(theme = f("string"), taakveld = f("string"), taakveld_title = f("string"),
                                                 confidence = f("string", enum = CONF), note = f("string", "empty_ok")))
  k <- paste(tm$theme, tm$taakveld)
  chk(L, "theme_to_taakveld", "(theme, taakveld) unique", !anyDuplicated(k), k[duplicated(k)])
  chk(L, "theme_to_taakveld", "`taakveld` exists in dim_taakveld", all(tm$taakveld %in% dims$taakveld$Key), setdiff(tm$taakveld, dims$taakveld$Key))
  ok <- title_ok(tm$taakveld, tm$taakveld_title)
  chk(L, "theme_to_taakveld", "`taakveld_title` matches CBS title", all(ok), paste(tm$taakveld, tm$taakveld_title)[!ok])
  if (exists("reg_current")) {
    ours <- reg_current[grepl("^gemeente (amsterdam|den haag|terneuzen)$", tolower(trimws(reg_current$organization))), ]
    themes <- unique(trimws(unlist(strsplit(na.omit(ours$category), ","))))
    chk(L, "theme_to_taakveld", "every theme used by the three municipalities is mapped", all(themes %in% tm$theme), setdiff(themes, tm$theme))
  }

  kw <- read_csv_text(file.path(d, "taakveld_keywords.csv"))
  check_fields(L, "taakveld_keywords", kw, list(pattern = f("string"), taakveld = f("string"), taakveld_title = f("string"),
                                                 note = f("string", "empty_ok")))
  chk(L, "taakveld_keywords", "`pattern` unique", !anyDuplicated(kw$pattern), kw$pattern[duplicated(kw$pattern)])
  compiles <- vapply(kw$pattern, function(p) !inherits(try(grepl(p, "x", perl = TRUE), silent = TRUE), "try-error"), TRUE)
  chk(L, "taakveld_keywords", "every pattern compiles", all(compiles), kw$pattern[!compiles])
  chk(L, "taakveld_keywords", "`taakveld` exists in dim_taakveld", all(kw$taakveld %in% dims$taakveld$Key), setdiff(kw$taakveld, dims$taakveld$Key))
  ok <- title_ok(kw$taakveld, kw$taakveld_title)
  chk(L, "taakveld_keywords", "`taakveld_title` matches CBS title", all(ok), paste(kw$taakveld, kw$taakveld_title)[!ok])

  al <- read_csv_text(file.path(d, "supplier_aliases.csv"))
  check_fields(L, "supplier_aliases", al, list(raw = f("string"), suppliers = f("string", "empty_ok"),
    kind = f("string", enum = c("vendor", "in_house", "open_source", "none", "unknown")), note = f("string", "empty_ok")))
  sq <- function(x) trimws(gsub("[\\s ]+", " ", x, perl = TRUE))
  chk(L, "supplier_aliases", "`raw` unique", !anyDuplicated(sq(al$raw)), al$raw[duplicated(sq(al$raw))])
  ok <- nzchar(al$suppliers) == (al$kind == "vendor")
  chk(L, "supplier_aliases", "`suppliers` filled exactly for vendors", all(ok), al$raw[!ok])
  if (exists("reg_current")) {
    prov_raw <- unique(sq(na.omit(ours$provider)))
    chk(L, "supplier_aliases", "every provider value of the three municipalities has a row",
        all(prov_raw %in% sq(al$raw)), setdiff(prov_raw, sq(al$raw)), warn = TRUE)
  }
})

# --- Report ---------------------------------------------------------------------------

counts <- table(factor(results$status, c("PASS", "WARN", "FAIL")))
by_layer <- as.data.frame.matrix(table(results$layer, factor(results$status, c("PASS", "WARN", "FAIL"))))
cat(sprintf("\n%d checks: %d pass, %d warn, %d fail\n\n", nrow(results), counts[["PASS"]], counts[["WARN"]], counts[["FAIL"]]))
print(by_layer)
nonpass <- results[results$status != "PASS", ]
if (nrow(nonpass)) { cat("\nNot passing:\n"); for (i in seq_len(nrow(nonpass)))
  cat(sprintf("  [%s] %s | %s | %s\n    %s\n", nonpass$status[i], nonpass$layer[i], nonpass$dataset[i], nonpass$check[i], nonpass$detail[i])) }

esc <- function(x) gsub("\\|", "\\\\|", gsub("[\r\n]+", " ", x))
md <- c("# Validation report", "",
        sprintf("Generated by `scripts/validate_schemas.R` on %s. Rules: the documents in this folder.", format(Sys.time(), "%Y-%m-%d %H:%M")), "",
        sprintf("**%d checks: %d pass, %d warn, %d fail.**", nrow(results), counts[["PASS"]], counts[["WARN"]], counts[["FAIL"]]), "",
        "| Layer | Pass | Warn | Fail |", "|---|---|---|---|",
        sprintf("| %s | %d | %d | %d |", rownames(by_layer), by_layer$PASS, by_layer$WARN, by_layer$FAIL), "")
if (nrow(nonpass)) md <- c(md, "## Not passing", "", "| Status | Layer | Dataset | Check | Detail |", "|---|---|---|---|---|",
                           sprintf("| %s | %s | %s | %s | %s |", nonpass$status, nonpass$layer, esc(nonpass$dataset), esc(nonpass$check), esc(nonpass$detail)), "")
md <- c(md, "## All checks", "", "| Status | Layer | Dataset | Check | Detail |", "|---|---|---|---|---|",
        sprintf("| %s | %s | %s | %s | %s |", results$status, results$layer, esc(results$dataset), esc(results$check), esc(results$detail)))
writeLines(md, report_file, useBytes = TRUE)
message("Wrote ", report_file)
if (counts[["FAIL"]] > 0) quit(status = 1)
