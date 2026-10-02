# Parse legal texts into provision units: one row per recital, chapter/section,
# article, paragraph, subparagraph, point, annex, annex section and annex item.
# Obligation extraction (pipeline step 2) runs over these rows; the version
# comparison aligns them across versions.
#
# Two readers, one output schema:
#   parse_formex()         adopted acts (Formex 4 from data/raw/ai_act/fmx4)
#   parse_proposal_xhtml() Commission proposals (XHTML converted from Word)
#
# Output: data/processed/provisions/<CELEX>.jsonl, one JSON object per unit:
#   unit_id     "<CELEX>:<path>", e.g. "32024R1689:art26.par9"
#   celex       source document
#   version     "final_2024", "proposal_2021", ...
#   seq         document order (1..n); parents always come before children
#   type        recital | chapter | section | title | article | paragraph |
#               subparagraph | point | annex | annex_section
#   path        hierarchical id inside the document: rct12, chIII.sec2,
#               art5.par1.sub1.pt_h, anxIII.pt_1.pt_a. Articles are not nested
#               under chapters in the path (article numbers are unique).
#   parent_id   unit_id of the parent (NA for top-level units)
#   depth       0 for top-level units
#   num         numbering as printed: "Article 5", "1.", "(a)", "ANNEX III"
#   label       normalised number: "5", "1", "a", "III"
#   heading     title text of chapters, sections, articles and annexes
#   text        the unit's own text, without child units; where child units
#               sit between two pieces of own text, " […] " marks the gap
#   full_text   own text plus all descendants, with their numbering
#   division    path of the enclosing chapter/section/title
#   article     article label for articles and everything inside them
#   source_file file the unit was read from
#   source_ref  Formex IDENTIFIER or XHTML paragraph index
#   notes       parser warnings (corrected numbering, duplicate paths)
#
# Formex creates subparagraph units when a paragraph has several unnumbered
# subparagraphs (ALINEA), matching citations like "Article 5(1), first
# subparagraph, point (h)". The proposal XHTML does not mark subparagraphs, so
# those texts are folded into the paragraph.
#
# Usage from the project root:  Rscript scripts/parse_provisions.R

library(xml2)

out_dir <- file.path("data", "processed", "provisions")

# --- Shared helpers -----------------------------------------------------------

# Collapses whitespace, including the non-breaking spaces EUR-Lex uses in headings.
squish <- function(x) trimws(gsub("[\\s ]+", " ", x, perl = TRUE))

clean_label <- function(x) {
  x <- gsub("[()\\s]", "", x, perl = TRUE)
  x <- sub("\\.$", "", x)
  gsub(".", "-", x, fixed = TRUE)
}

# Number of a heading line ("CHAPTER III" -> "III"). Some proposal headings are
# lower case in the XHTML ("title v") and only shown in capitals by styling.
roman_or_num <- function(x) toupper(sub("^\\S+ ([IVXLCivxlc0-9]+)\\b.*$", "\\1", squish(x), perl = TRUE))

# Collects rows in document order. Returns an environment with add(), append_text().
new_builder <- function(celex, version) {
  b <- new.env()
  b$rows <- list()
  b$paths <- new.env()
  b$has_kids <- new.env()
  b$add <- function(type, path, parent = NA, num = NA, label = NA, heading = NA,
                    text = "", division = NA, article = NA, file = NA, ref = NA, note = NA) {
    if (!is.null(b$paths[[path]])) {
      k <- 2
      while (!is.null(b$paths[[paste0(path, "_dup", k)]])) k <- k + 1
      note <- paste(na.omit(c(note, paste0("duplicate path ", path))), collapse = "; ")
      path <- paste0(path, "_dup", k)
    }
    uid <- paste0(celex, ":", path)
    b$paths[[path]] <- length(b$rows) + 1
    if (!is.na(parent)) b$has_kids[[parent]] <- TRUE
    b$rows[[length(b$rows) + 1]] <- list(
      unit_id = uid, celex = celex, version = version, type = type, path = path,
      parent_id = parent, num = num, label = label, heading = heading, text = text,
      division = division, article = article, source_file = file, source_ref = ref, notes = note)
    list(id = uid, path = path, idx = length(b$rows))
  }
  b$append_text <- function(idx, txt) {
    txt <- squish(txt)
    if (!nzchar(txt)) return(invisible())
    old <- b$rows[[idx]]$text
    sep <- if (isTRUE(b$has_kids[[b$rows[[idx]]$unit_id]])) " […] " else " "
    b$rows[[idx]]$text <- if (nzchar(old)) paste0(old, sep, txt) else txt
  }
  b
}

# Rows -> data frame with depth and full_text.
finalize <- function(b) {
  rows <- b$rows
  fields <- names(rows[[1]])
  df <- as.data.frame(lapply(setNames(fields, fields), function(f)
    vapply(rows, function(r) { v <- r[[f]]; if (is.null(v) || length(v) == 0 || is.na(v)) NA_character_ else as.character(v) }, "")),
    stringsAsFactors = FALSE)
  df$seq <- seq_len(nrow(df))
  idx <- setNames(df$seq, df$unit_id)
  df$depth <- 0L
  for (i in seq_len(nrow(df))) if (!is.na(df$parent_id[i])) df$depth[i] <- df$depth[idx[[df$parent_id[i]]]] + 1L
  display <- squish(paste(ifelse(is.na(df$num), "", df$num), ifelse(is.na(df$heading), "", df$heading)))
  ft <- ifelse(is.na(df$text), "", df$text)
  kids <- split(df$seq, factor(df$parent_id, levels = df$unit_id))
  for (i in rev(seq_len(nrow(df)))) {
    ch <- kids[[df$unit_id[i]]]
    if (length(ch)) {
      parts <- c(ft[i], squish(paste(display[ch], ft[ch])))
      ft[i] <- paste(parts[nzchar(parts)], collapse = " ")
    }
  }
  df$full_text <- ft
  df[, c("unit_id", "celex", "version", "seq", "type", "path", "parent_id", "depth",
         "num", "label", "heading", "text", "full_text", "division", "article",
         "source_file", "source_ref", "notes")]
}

write_units <- function(df, celex) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  f <- file.path(out_dir, paste0(celex, ".jsonl"))
  con <- file(f, open = "w", encoding = "UTF-8")
  jsonlite::stream_out(df, con, na = "null", verbose = FALSE)
  close(con)
  f
}

# --- Formex reader --------------------------------------------------------------

# Elements whose content belongs to child units (or is not text at all).
SKIP <- c("LIST", "NOTE", "NP", "GR.SEQ", "TITLE", "NO.P", "NO.PARAG",
          "TI.ART", "STI.ART", "PARAG")
BLOCK <- c("P", "ALINEA", "TXT", "TI", "STI", "NP", "ITEM", "CONTENTS", "GR.SEQ")

# Text of a Formex node. Lists in `skip` are replaced by a gap marker; text
# inside QUOT.S (quoted amending text) is always kept whole.
render <- function(node, skip = SKIP) {
  out <- character()
  walk <- function(n, in_quote) {
    for (ch in xml_contents(n)) {
      type <- xml_type(ch)
      if (type == "text") { out[length(out) + 1] <<- xml_text(ch); next }
      if (type != "element") next
      nm <- xml_name(ch)
      if (nm == "NOTE") next
      if (nm %in% c("QUOT.START", "QUOT.END")) {
        out[length(out) + 1] <<- intToUtf8(strtoi(xml_attr(ch, "CODE"), 16L)); next
      }
      if (!in_quote && nm %in% skip) {
        if (nm %in% c("LIST", "NP", "GR.SEQ", "PARAG")) out[length(out) + 1] <<- "\u0001"
        next
      }
      walk(ch, in_quote || nm == "QUOT.S")
      if (nm %in% BLOCK) out[length(out) + 1] <<- " "
    }
  }
  walk(node, FALSE)
  s <- gsub("[\\s ]+", " ", paste(out, collapse = ""), perl = TRUE)
  s <- gsub("^[\\s\u0001]+|[\\s\u0001]+$", "", s, perl = TRUE)
  gsub("\\s*\u0001[\\s\u0001]*", " […] ", s, perl = TRUE)
}

parse_formex <- function(fmx_dir, celex, version) {
  b <- new_builder(celex, version)
  files <- list.files(fmx_dir, "\\.fmx\\.xml$", full.names = TRUE)
  roots <- vapply(files, function(f) xml_name(read_xml(f)), "")
  main <- files[roots == "ACT"]
  annexes <- sort(files[roots == "ANNEX"])
  if (length(main) != 1) stop("Expected one ACT file in ", fmx_dir)
  act <- read_xml(main)
  mf <- basename(main)

  # Items of a LIST, or NPs placed directly in a container.
  parse_np <- function(np, parent, i, ctx, file) {
    no <- xml_find_first(np, "NO.P")
    num <- if (inherits(no, "xml_missing")) NA else squish(xml_text(no))
    lab <- if (is.na(num) || !nzchar(clean_label(num))) as.character(i) else clean_label(num)
    u <- b$add("point", paste0(parent$path, ".pt_", lab), parent$id, num, lab,
               text = render(np), division = ctx$division, article = ctx$article, file = file)
    walk_content(np, u, ctx, file)
  }
  parse_list <- function(lst, parent, ctx, file) {
    items <- xml_find_all(lst, "./ITEM")
    for (i in seq_along(items)) {
      np <- xml_find_first(items[[i]], "./NP")
      parse_np(if (inherits(np, "xml_missing")) items[[i]] else np, parent, i, ctx, file)
    }
  }
  parse_section <- function(gr, parent, i, ctx, file) {
    heading <- squish(render(xml_find_first(gr, "./TITLE"), skip = "NOTE"))
    lab <- if (grepl("^Section\\s+[A-Z0-9]+", heading)) sub("^Section\\s+([A-Z0-9]+).*$", "\\1", heading) else as.character(i)
    u <- b$add("annex_section", paste0(parent$path, ".sec", lab), parent$id, NA, lab, heading,
               text = render(gr), division = ctx$division, file = file)
    walk_content(gr, u, ctx, file)
  }
  # Child units anywhere below `node`, in document order, without entering
  # units already handled (ITEM/NP) or quoted amending text.
  walk_content <- function(node, owner, ctx, file) {
    n_np <- 0; n_sec <- 0
    for (ch in xml_children(node)) {
      nm <- xml_name(ch)
      if (nm == "LIST") parse_list(ch, owner, ctx, file)
      else if (nm == "NP") { n_np <- n_np + 1; parse_np(ch, owner, n_np, ctx, file) }
      else if (nm == "GR.SEQ") { n_sec <- n_sec + 1; parse_section(ch, owner, n_sec, ctx, file) }
      else if (nm %in% c("P", "ALINEA", "CONTENTS")) walk_content(ch, owner, ctx, file)
    }
  }
  # Body of an article or paragraph: numbered paragraphs, several
  # subparagraphs, or a single block of text with optional points.
  parse_body <- function(node, owner, ctx, file) {
    paragraphs <- xml_find_all(node, "./PARAG")
    alineas <- xml_find_all(node, "./ALINEA")
    for (p in paragraphs) {
      num <- squish(xml_text(xml_find_first(p, "./NO.PARAG")))
      lab <- clean_label(num)
      single <- length(xml_find_all(p, "./ALINEA")) <= 1
      u <- b$add("paragraph", paste0(owner$path, ".par", lab), owner$id, num, lab,
                 text = if (single) render(p) else "", division = ctx$division,
                 article = ctx$article, file = file, ref = xml_attr(p, "IDENTIFIER"))
      parse_body(p, u, ctx, file)
    }
    if (length(alineas) > 1) {
      for (i in seq_along(alineas)) {
        u <- b$add("subparagraph", paste0(owner$path, ".sub", i), owner$id, NA, as.character(i),
                   text = render(alineas[[i]]), division = ctx$division,
                   article = ctx$article, file = file)
        walk_content(alineas[[i]], u, ctx, file)
      }
    } else if (length(alineas) == 1) {
      walk_content(alineas[[1]], owner, ctx, file)
    }
  }
  parse_article <- function(a, parent, ctx) {
    num <- squish(xml_text(xml_find_first(a, "./TI.ART")))
    lab <- sub("^Article\\s+", "", num)
    ctx$article <- lab
    has_own <- length(xml_find_all(a, "./PARAG")) == 0 && length(xml_find_all(a, "./ALINEA")) <= 1
    u <- b$add("article", paste0("art", lab), parent$id, num, lab,
               squish(render(xml_find_first(a, "./STI.ART"), skip = "NOTE")),
               text = if (has_own) render(a) else "", division = ctx$division,
               article = lab, file = mf, ref = xml_attr(a, "IDENTIFIER"))
    parse_body(a, u, ctx, mf)
  }
  walk_divisions <- function(node, parent, ctx) {
    for (ch in xml_children(node)) {
      nm <- xml_name(ch)
      if (nm == "DIVISION") {
        ti <- squish(render(xml_find_first(ch, "./TITLE/TI"), skip = "NOTE"))
        kind <- tolower(sub(" .*$", "", ti))
        lab <- roman_or_num(ti)
        prefix <- c(chapter = "ch", section = "sec", title = "ti", part = "pt")[[kind]]
        path <- if (is.na(parent$path)) paste0(prefix, lab) else paste0(parent$path, ".", prefix, lab)
        u <- b$add(kind, path, parent$id, ti, lab,
                   squish(render(xml_find_first(ch, "./TITLE/STI"), skip = "NOTE")),
                   division = path, file = mf)
        walk_divisions(ch, u, list(division = path, article = NA))
      } else if (nm == "ARTICLE") {
        parse_article(ch, parent, ctx)
      }
    }
  }

  # Recitals: full text including any lists.
  for (c in xml_find_all(act, "//PREAMBLE//CONSID")) {
    np <- xml_find_first(c, "./NP")
    num <- squish(xml_text(xml_find_first(np, "./NO.P")))
    lab <- clean_label(num)
    b$add("recital", paste0("rct", lab), NA, num, lab,
          text = render(np, skip = c("NOTE", "NO.P")), file = mf)
  }
  walk_divisions(xml_find_first(act, "//ENACTING.TERMS"), list(id = NA, path = NA),
                 list(division = NA, article = NA))

  for (f in annexes) {
    ax <- read_xml(f)
    ti <- squish(render(xml_find_first(ax, "./TITLE/TI"), skip = "NOTE"))
    lab <- roman_or_num(ti)
    contents <- xml_find_first(ax, "./CONTENTS")
    ctx <- list(division = paste0("anx", lab), article = NA)
    u <- b$add("annex", paste0("anx", lab), NA, ti, lab,
               squish(render(xml_find_first(ax, "./TITLE/STI"), skip = "NOTE")),
               text = render(contents), division = ctx$division, file = basename(f))
    walk_content(contents, u, ctx, basename(f))
  }
  finalize(b)
}

# --- Proposal XHTML reader --------------------------------------------------------

# Split an XHTML paragraph into its printed number and its text.
xhtml_p <- function(p) {
  num_node <- xml_find_first(p, ".//span[@class='num']")
  num <- if (inherits(num_node, "xml_missing")) NA else squish(xml_text(num_node))
  txt <- squish(xml_text(p))
  if (!is.na(num) && startsWith(txt, num)) txt <- squish(substring(txt, nchar(num) + 1))
  list(num = num, text = txt)
}

strip_footnotes <- function(doc) {
  xml_remove(xml_find_all(doc, "//a[@class='footnoteRef'] | //span[@class='FootnoteReference']"))
  doc
}

parse_proposal_xhtml <- function(prop_dir, celex, version) {
  b <- new_builder(celex, version)
  files <- sort(list.files(prop_dir, "\\.xhtml$", full.names = TRUE))
  docs <- lapply(files, function(f) strip_footnotes(read_html(f)))
  is_annex <- vapply(docs, function(d) length(xml_find_all(d, "//p[@class='Annexetitre']")) > 0, TRUE)
  main <- docs[!is_annex][[1]]; mf <- basename(files[!is_annex][1])

  ps <- xml_find_all(main, "//p")
  cls <- sub("^li ", "", xml_attr(ps, "class"))

  # Recitals
  for (i in which(cls == "ManualConsidrant")) {
    x <- xhtml_p(ps[[i]])
    lab <- clean_label(x$num)
    b$add("recital", paste0("rct", lab), NA, x$num, lab, text = x$text, file = mf, ref = paste0("p", i))
  }

  # Enacting terms
  from <- which(cls == "Formuledadoption")[1]; to <- which(cls == "Fait")[1]
  if (is.na(from) || is.na(to)) stop("Enacting terms not found in ", mf)
  levels <- c(title = 1, chapter = 2, section = 3)
  prefix <- c(title = "ti", chapter = "ch", section = "sec")
  divs <- list()                 # open divisions, outermost first
  pending_heading <- NULL        # division waiting for its heading line
  art <- NULL; par <- NULL; pt0 <- NULL; pt1 <- NULL
  last_lab <- new.env()          # last point label per parent

  # Word auto-numbering sometimes survives the conversion wrongly ("(1)" twice,
  # "(a)" twice). A number or single letter that repeats or goes backwards is
  # replaced by the successor of the previous label.
  point <- function(parent, x, i, ctx_art) {
    lab <- clean_label(x$num); note <- NA
    prev <- last_lab[[parent$id]]
    if (!is.null(prev)) {
      fixed <- NA
      if (grepl("^[0-9]+$", lab) && grepl("^[0-9]+$", prev) && as.integer(lab) <= as.integer(prev))
        fixed <- as.character(as.integer(prev) + 1)
      if (grepl("^[a-z]$", lab) && grepl("^[a-z]$", prev) && lab <= prev && prev != "z")
        fixed <- letters[match(prev, letters) + 1]
      if (!is.na(fixed)) {
        note <- paste0("numbering corrected: source shows ", x$num)
        lab <- fixed
      }
    }
    last_lab[[parent$id]] <- lab
    b$add("point", paste0(parent$path, ".pt_", lab), parent$id, x$num, lab, text = x$text,
          division = divs[[length(divs)]]$path, article = ctx_art, file = mf,
          ref = paste0("p", i), note = note)
  }

  for (i in seq.int(from + 1, to - 1)) {
    k <- cls[i]
    if (k == "SectionTitle") {
      t <- squish(xml_text(ps[[i]]))
      kind <- tolower(sub(" .*$", "", t))
      if (kind %in% names(levels)) {
        while (length(divs) && divs[[length(divs)]]$level >= levels[[kind]]) divs[[length(divs)]] <- NULL
        parent <- if (length(divs)) divs[[length(divs)]] else list(id = NA, path = NA)
        lab <- roman_or_num(t)
        path <- if (is.na(parent$path)) paste0(prefix[[kind]], lab) else paste0(parent$path, ".", prefix[[kind]], lab)
        u <- b$add(kind, path, parent$id, t, lab, division = path, file = mf, ref = paste0("p", i))
        divs[[length(divs) + 1]] <- c(u, level = levels[[kind]])
        pending_heading <- u$idx
      } else if (!is.null(pending_heading)) {
        b$rows[[pending_heading]]$heading <- t
        pending_heading <- NULL
      }
      next
    }
    if (k == "Titrearticle") {
      spans <- xml_find_all(ps[[i]], "./span")
      num <- squish(xml_text(spans[[1]]))
      lab <- sub("^Article\\s+", "", num)
      heading <- if (length(spans) > 1) squish(paste(xml_text(spans[-1]), collapse = " ")) else NA
      parent <- if (length(divs)) divs[[length(divs)]] else list(id = NA)
      art <- b$add("article", paste0("art", lab), parent$id, num, lab, heading,
                   division = divs[[length(divs)]]$path, article = lab, file = mf, ref = paste0("p", i))
      art$label <- lab
      par <- NULL; pt0 <- NULL; pt1 <- NULL
      next
    }
    if (is.null(art)) next
    x <- xhtml_p(ps[[i]])
    owner <- if (is.null(par)) art else par
    if (k %in% c("ManualNumPar1", "NumPar1") && !is.na(x$num)) {
      lab <- clean_label(x$num)
      par <- b$add("paragraph", paste0(art$path, ".par", lab), art$id, x$num, lab, text = x$text,
                   division = divs[[length(divs)]]$path, article = art$label, file = mf, ref = paste0("p", i))
      pt0 <- NULL; pt1 <- NULL
    } else if (k %in% c("Point0", "Point0number")) {
      # Numbered list items such as the Article 3 definitions
      pt0 <- point(owner, x, i, art$label); pt1 <- NULL
    } else if (k == "Point1") {
      # Letter points nest under a preceding numbered item, e.g. a definition with (a), (b)
      pt1 <- point(if (is.null(pt0)) owner else pt0, x, i, art$label)
    } else if (k == "Point2") {
      point(if (is.null(pt1)) (if (is.null(pt0)) owner else pt0) else pt1, x, i, art$label)
    } else if (k %in% c("Normal", "Text1", "NumPar1")) {
      # Unnumbered subparagraphs are folded into the paragraph or article
      b$append_text(if (is.null(par)) art$idx else par$idx, x$text)
    }
  }

  # Annexes
  if (any(is_annex)) {
    ad <- docs[is_annex][[1]]; af <- basename(files[is_annex][1])
    aps <- xml_find_all(ad, "//p")
    acls <- sub("^li ", "", xml_attr(aps, "class"))
    anx <- NULL; sec <- NULL; item <- NULL
    for (i in seq_along(aps)) {
      k <- acls[i]
      if (identical(k, "Annexetitre")) {
        t <- squish(xml_text(aps[[i]]))
        lab <- sub("^ANNEX ([IVXLC]+).*$", "\\1", t)
        heading <- squish(sub("^ANNEX [IVXLC]+", "", t))
        # The first section heading can sit inside the annex title line (Annex II)
        first_sec <- regmatches(heading, regexpr("Section [A-Z0-9]+\\b.*$", heading))
        if (length(first_sec)) heading <- squish(sub("Section [A-Z0-9]+\\b.*$", "", heading))
        anx <- b$add("annex", paste0("anx", lab), NA, paste("ANNEX", lab), lab, heading,
                     division = paste0("anx", lab), file = af, ref = paste0("p", i))
        sec <- NULL; item <- NULL
        if (length(first_sec)) {
          slab <- sub("^Section ([A-Z0-9]+).*$", "\\1", first_sec)
          sec <- b$add("annex_section", paste0(anx$path, ".sec", slab), anx$id, NA, slab, first_sec,
                       division = anx$path, file = af, ref = paste0("p", i))
        }
        next
      }
      if (is.null(anx) || is.na(k)) next
      x <- xhtml_p(aps[[i]])
      owner <- if (is.null(sec)) anx else sec
      if (k == "Normal" && grepl("^Section\\s+[A-Z0-9]+\\b", x$text)) {
        lab <- sub("^Section\\s+([A-Z0-9]+).*$", "\\1", x$text)
        sec <- b$add("annex_section", paste0(anx$path, ".sec", lab), anx$id, NA, lab, x$text,
                     division = anx$path, file = af, ref = paste0("p", i))
        item <- NULL
      } else if (k %in% c("NumPar1", "NumPar2", "Point0letter")) {
        lab <- clean_label(x$num)
        parent <- owner
        # "3.1." nests under item 3 when it exists
        if (grepl("-", lab)) {
          top <- paste0(owner$path, ".pt_", sub("-.*$", "", lab))
          if (!is.null(b$paths[[top]])) parent <- list(id = paste0(b$rows[[b$paths[[top]]]]$unit_id), path = top)
        }
        item <- b$add("point", paste0(parent$path, ".pt_", lab), parent$id, x$num, lab, text = x$text,
                      division = anx$path, file = af, ref = paste0("p", i))
      } else if (k == "Point1letter") {
        parent <- if (is.null(item)) owner else item
        b$add("point", paste0(parent$path, ".pt_", clean_label(x$num)), parent$id, x$num,
              clean_label(x$num), text = x$text, division = anx$path, file = af, ref = paste0("p", i))
      } else if (k %in% c("Normal", "Text1")) {
        b$append_text(if (k == "Text1" && !is.null(item)) item$idx else owner$idx, x$text)
      }
    }
  }
  finalize(b)
}

# --- Checks -------------------------------------------------------------------------

summarise_units <- function(df, expected) {
  cat("\n==", df$celex[1], "(", df$version[1], ") ==\n")
  print(table(df$type))
  n <- function(t) sum(df$type == t)
  arts <- as.integer(df$label[df$type == "article"])
  checks <- c(
    recitals = n("recital") == expected$recitals,
    articles = identical(sort(arts), seq_len(expected$articles)),
    annexes  = n("annex") == expected$annexes,
    definitions = sum(df$parent_id == paste0(df$celex[1], ":art3"), na.rm = TRUE) == expected$definitions
  )
  print(checks)
  leaves_empty <- df$type %in% c("paragraph", "subparagraph", "point") &
    !nzchar(df$text) & !(df$unit_id %in% df$parent_id)
  cat("empty leaf units:", sum(leaves_empty), "\n")
  notes <- df[!is.na(df$notes), c("unit_id", "notes")]
  cat("parser notes:", nrow(notes), "\n")
  if (nrow(notes)) print(utils::head(notes, 10), row.names = FALSE)
  invisible(checks)
}

if (sys.nframe() == 0) {
  final <- parse_formex(file.path("data", "raw", "ai_act", "fmx4"), "32024R1689", "final_2024")
  summarise_units(final, list(recitals = 180, articles = 113, annexes = 13, definitions = 68))
  message("Wrote ", write_units(final, "32024R1689"))

  prop <- parse_proposal_xhtml(file.path("data", "raw", "proposals", "52021PC0206"), "52021PC0206", "proposal_2021")
  summarise_units(prop, list(recitals = 89, articles = 85, annexes = 9, definitions = 44))
  message("Wrote ", write_units(prop, "52021PC0206"))
}
