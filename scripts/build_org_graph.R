# Build the organization graph (pipeline step 3) for the project's
# municipalities, following docs/org-graph-schema.md.
#
# Inputs:
#   data/raw/algorithm_register/algoritmeregister_NLD_current.csv   systems
#   data/raw/algorithm_register/algoritmeregister_NLD_history.csv   departments (older standard)
#   data/raw/cbs_iv3/iv3_2025.csv, dim_taakveld.csv                  budgets per task field
#   data/reference/taakveld_keywords.csv, theme_to_taakveld.csv      system -> task field
#
# Outputs (data/processed/org_graph/):
#   nodes.jsonl   one object per node; "type" is municipality | department |
#                 system | supplier | taskfield
#   edges.jsonl   one object per edge: from, to, type, source, source_ref,
#                 confidence, plus edge-specific fields
# Every node and edge carries source, source_ref and confidence. Facts that
# are missing stay missing; fields reserved for agents are null.
#
# Usage from the project root:  Rscript scripts/build_org_graph.R

reg_dir <- file.path("data", "raw", "algorithm_register")
iv3_dir <- file.path("data", "raw", "cbs_iv3")
ref_dir <- file.path("data", "reference")
out_dir <- file.path("data", "processed", "org_graph")

MUNICIPALITIES <- data.frame(
  code = c("GM0363", "GM0518", "GM0715"),
  name = c("Amsterdam", "Den Haag", "Terneuzen"),
  register_name = c("gemeente amsterdam", "gemeente den haag", "gemeente terneuzen"),
  stringsAsFactors = FALSE
)

read_csv_utf8 <- function(f, ...) read.csv(f, check.names = FALSE, stringsAsFactors = FALSE,
                                           na.strings = c("", "NA"), encoding = "UTF-8",
                                           fileEncoding = "UTF-8-BOM", ...)
slug <- function(x) gsub("^-|-$", "", gsub("[^a-z0-9]+", "-", tolower(iconv(x, "UTF-8", "ASCII//TRANSLIT"))))

# --- Inputs -------------------------------------------------------------------------

reg  <- read_csv_utf8(file.path(reg_dir, "algoritmeregister_NLD_current.csv"))
hist <- read_csv_utf8(file.path(reg_dir, "algoritmeregister_NLD_history.csv"))
iv3  <- read_csv_utf8(file.path(iv3_dir, "iv3_2025.csv"), colClasses = c(TaakveldBalanspost = "character"))
dim_tv <- read_csv_utf8(file.path(iv3_dir, "dim_taakveld.csv"), colClasses = "character")
# Task-field codes must stay text: as numbers, 0.1 and 0.10 would merge.
kw <- read_csv_utf8(file.path(ref_dir, "taakveld_keywords.csv"), colClasses = "character")
tm <- read_csv_utf8(file.path(ref_dir, "theme_to_taakveld.csv"), colClasses = "character")

muni_of <- function(org) MUNICIPALITIES$code[match(tolower(trimws(org)), MUNICIPALITIES$register_name)]
reg$muni <- muni_of(reg$organization)
sys <- reg[!is.na(reg$muni), ]
hist$muni <- muni_of(hist$organization)

nodes <- list(); edges <- list()
add_nodes <- function(df) nodes[[length(nodes) + 1]] <<- df
add_edges <- function(df) if (nrow(df)) edges[[length(edges) + 1]] <<- df
edge_df <- function(from, to, type, source, source_ref, confidence, ...) {
  data.frame(from = from, to = to, type = type, source = source, source_ref = source_ref,
             confidence = confidence, ..., stringsAsFactors = FALSE)
}

# --- Municipalities ---------------------------------------------------------------------

org_ids <- tapply(sys$org_id, sys$muni, function(x) x[1])
add_nodes(data.frame(
  id = MUNICIPALITIES$code, type = "municipality", name = MUNICIPALITIES$name,
  register_org_id = as.character(org_ids[MUNICIPALITIES$code]),
  source = "cbs_iv3", source_ref = MUNICIPALITIES$code, confidence = "high",
  stringsAsFactors = FALSE))

# --- Systems ----------------------------------------------------------------------------

assess <- tolower(paste(sys$impacttoetsen, sys$impacttoetsen_grouping))
sys_id <- paste0("sys:", sys$algorithm_id)
add_nodes(data.frame(
  id = sys_id, type = "system", municipality = sys$muni, name = trimws(sys$name),
  description_short = sys$description_short, goal = sys$goal, status = sys$status,
  begin_date = sys$begin_date, end_date = sys$end_date,
  self_category = sys$publication_category, themes = sys$category,
  has_dpia = grepl("dpia|data protection impact", assess),
  has_iama = grepl("iama|mensenrechten", assess),
  assessments_raw = sys$impacttoetsen,
  has_human_oversight_text = !is.na(sys$human_intervention),
  methods_and_models = sys$methods_and_models, human_intervention = sys$human_intervention,
  risks = sys$risks, source_data = sys$source_data, lawful_basis = sys$lawful_basis,
  provider_raw = sys$provider, publication_dt = sys$publication_dt,
  aiact_class = NA_character_, aiact_role = NA_character_,
  source = "register_current", source_ref = sys$algorithm_id, confidence = "high",
  stringsAsFactors = FALSE))
add_edges(edge_df(sys$muni, sys_id, "operates", "register_current", sys$algorithm_id, "high"))

# --- Departments (latest version of each system that still named one) -----------------------

h <- hist[!is.na(hist$muni) & !is.na(hist$department) & hist$algorithm_id %in% sys$algorithm_id, ]
h <- h[order(h$algorithm_id, h$publication_dt, decreasing = TRUE), ]
h <- h[!duplicated(h$algorithm_id), ]
if (nrow(h)) {
  h$dept_name <- trimws(h$department)
  h$dept_id <- paste0(h$muni, ":dept:", slug(h$dept_name))
  d <- h[!duplicated(h$dept_id), ]
  add_nodes(data.frame(id = d$dept_id, type = "department", municipality = d$muni, name = d$dept_name,
                       source = "register_history", source_ref = d$algorithm_id, confidence = "high",
                       stringsAsFactors = FALSE))
  add_edges(edge_df(d$muni, d$dept_id, "has_department", "register_history", d$algorithm_id, "high"))
  add_edges(edge_df(h$dept_id, paste0("sys:", h$algorithm_id), "runs", "register_history",
                    paste0(h$algorithm_id, "@", h$publication_dt), "medium",
                    note = "department from an older version of the description"))
}

# --- Suppliers --------------------------------------------------------------------------
# provider is free text. data/reference/supplier_aliases.csv maps each known
# raw value to one or more suppliers (";"-separated) and a kind: vendor,
# in_house, open_source, none or unknown. Values not in the table fall back to
# a rule-based cut and get low confidence; add them to the table to fix them.

norm_supplier <- function(x) {
  x <- trimws(x)
  short <- sub("\\s*[,.(;].*$", "", x)
  short <- sub("\\s+(is de leverancier|levert|maakt gebruik).*$", "", short, ignore.case = TRUE)
  # Strip trailing company-form and country words, repeatedly ("Centric Netherlands BV")
  repeat {
    cut <- sub("\\s+(b\\.?v\\.?|n\\.?v\\.?|netherlands|nederland|group|gmbh|ltd|inc)\\.?\\s*$", "", short, ignore.case = TRUE)
    if (identical(cut, short)) break
    short <- cut
  }
  trimws(short)
}
aliases <- read_csv_utf8(file.path(ref_dir, "supplier_aliases.csv"), colClasses = "character")
# Collapses whitespace, including non-breaking spaces (the register uses them)
squish <- function(x) trimws(gsub("[\\s ]+", " ", x, perl = TRUE))
aliases$raw <- squish(aliases$raw)
s <- list()
for (i in which(!is.na(sys$provider))) {
  raw <- squish(sys$provider[i]); a <- match(raw, aliases$raw)
  if (!is.na(a)) {
    kind <- aliases$kind[a]
    names_i <- if (kind == "in_house") "In-house" else if (kind == "vendor") strsplit(aliases$suppliers[a], ";")[[1]] else character()
    conf <- "high"; src <- "supplier_alias"
  } else {
    kind <- if (grepl("^(intern|eigen|zelf)|intern ontwikkeld|zelf ontwikkeld", tolower(raw))) "in_house" else "vendor"
    names_i <- if (kind == "in_house") "In-house" else norm_supplier(raw)
    conf <- "low"; src <- "supplier_rule"
  }
  if (!length(names_i)) next   # none, unknown, open source: no supplier edge
  ids <- if (kind == "in_house") paste0(sys$muni[i], ":sup:in-house") else paste0("sup:", slug(names_i))
  s[[length(s) + 1]] <- data.frame(id = ids, name = names_i, kind = kind, muni = sys$muni[i], conf = conf,
                                   src = src, ref = sys$algorithm_id[i], stringsAsFactors = FALSE)
}
s <- do.call(rbind, s)
n_muni <- tapply(s$muni, s$id, function(x) length(unique(x)))
su <- s[!duplicated(s$id), ]
add_nodes(data.frame(id = su$id, type = "supplier", name = su$name, in_house = su$kind == "in_house",
                     n_municipalities = as.integer(n_muni[su$id]),
                     source = su$src, source_ref = su$ref, confidence = su$conf,
                     stringsAsFactors = FALSE))
add_edges(edge_df(paste0("sys:", s$ref), s$id, "supplied_by", s$src, s$ref, s$conf))

# --- Task fields and budgets ---------------------------------------------------------------

iv3$value <- ifelse(is.na(iv3$release2_keur), iv3$release1_keur, iv3$release2_keur)
iv3$value_source <- ifelse(is.na(iv3$release2_keur), "release1", "release2")
tf <- iv3[grepl("^[0-8]\\.", iv3$TaakveldBalanspost) & grepl("^L", iv3$Categorie), ]
agg <- function(rep, cats = NULL, exclude = "L7.1") {
  x <- tf[tf$Verslagsoort == rep & !(tf$Categorie %in% exclude), ]
  if (!is.null(cats)) x <- x[x$Categorie %in% cats, ]
  tapply(x$value, paste(x$Gemeenten, x$TaakveldBalanspost), sum, na.rm = TRUE)
}
key <- unique(paste(tf$Gemeenten, tf$TaakveldBalanspost))
pick <- function(v) { r <- as.numeric(v[key]); r[is.na(r)] <- 0; r }
budget <- pick(agg("2025X000")); actual <- pick(agg("2025X005"))
tf_nodes <- data.frame(
  id = paste0(sub(" ", ":tf:", key)), type = "taskfield",
  municipality = sub(" .*$", "", key), code = sub("^\\S+ ", "", key), stringsAsFactors = FALSE)
tf_nodes$title <- dim_tv$Title[match(tf_nodes$code, dim_tv$Key)]
tf_nodes$is_overhead <- tf_nodes$code == "0.4"
tf_nodes$budget_2025_keur <- budget
tf_nodes$actuals_2025_keur <- actual
tf_nodes$budget_personnel_keur <- pick(agg("2025X000", c("L1.1", "L3.5.1")))
tf_nodes$budget_goods_services_keur <- pick(agg("2025X000", "L3.8"))
tf_nodes$actuals_personnel_keur <- pick(agg("2025X005", c("L1.1", "L3.5.1")))
tf_nodes$actuals_goods_services_keur <- pick(agg("2025X005", "L3.8"))
tf_nodes$source <- "cbs_iv3"; tf_nodes$source_ref <- paste0("45071NED ", key)
tf_nodes$confidence <- "high"
tf_nodes <- tf_nodes[order(tf_nodes$municipality, as.numeric_version(tf_nodes$code)), ]
add_nodes(tf_nodes)
add_edges(edge_df(tf_nodes$municipality, tf_nodes$id, "spends_on", "cbs_iv3", tf_nodes$source_ref, "high",
                  budget_2025_keur = tf_nodes$budget_2025_keur))
ov <- tf_nodes[tf_nodes$is_overhead, ]
add_edges(edge_df(ov$id, ov$municipality, "overhead_of", "fixed", "BBV task field 0.4", "high"))

# --- System -> task field ---------------------------------------------------------------------
# Keyword rules on name and short description first; the theme map only when
# no rule fires. Low-confidence theme rows are not used.

txt <- tolower(paste(sys$name, sys$description_short))
fund <- list()
for (i in seq_len(nrow(sys))) {
  hit <- which(vapply(kw$pattern, function(p) grepl(p, txt[i], perl = TRUE), TRUE))
  if (length(hit)) {
    r <- kw[hit, ]; r <- r[!duplicated(r$taakveld), ]
    fund[[i]] <- edge_df(sys_id[i], paste0(sys$muni[i], ":tf:", r$taakveld), "funded_from", "keyword_rule",
                         r$pattern, "medium")
  } else if (!is.na(sys$category[i])) {
    th <- trimws(strsplit(sys$category[i], ",")[[1]])
    r <- tm[tm$theme %in% th & tm$confidence %in% c("high", "medium"), ]
    r <- r[!duplicated(r$taakveld), ]
    if (nrow(r)) fund[[i]] <- edge_df(sys_id[i], paste0(sys$muni[i], ":tf:", r$taakveld), "funded_from",
                                      "theme_map", r$theme, r$confidence)
  }
}
fund <- do.call(rbind, fund)
# Only link to task fields that exist in the municipality's Iv3 data
missing_tf <- setdiff(fund$to, tf_nodes$id)
if (length(missing_tf)) warning("funded_from targets not in Iv3: ", paste(missing_tf, collapse = ", "))
fund <- fund[fund$to %in% tf_nodes$id, ]
add_edges(fund)

# --- Write ------------------------------------------------------------------------------------

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
write_jsonl <- function(parts, f) {
  con <- file(f, open = "w", encoding = "UTF-8")
  for (p in parts) jsonlite::stream_out(p, con, na = "null", verbose = FALSE)
  close(con)
}
write_jsonl(nodes, file.path(out_dir, "nodes.jsonl"))
write_jsonl(edges, file.path(out_dir, "edges.jsonl"))

# --- Summary ----------------------------------------------------------------------------------

all_nodes <- do.call(rbind, lapply(nodes, function(n) n[, c("id", "type")]))
all_edges <- do.call(rbind, lapply(edges, function(e) e[, c("from", "to", "type", "source", "confidence")]))
cat("Nodes:\n"); print(table(all_nodes$type))
cat("\nEdges:\n"); print(table(all_edges$type, all_edges$source))
sn <- nodes[[2]]
cat("\nSystems per municipality and self-classification:\n"); print(table(sn$municipality, sn$self_category))
funded <- unique(fund$from)
cat("\nSystems without a task field:", sum(!sys_id %in% funded), "\n")
cat("Systems with a department:", sum(sys_id %in% edges[[which(sapply(edges, function(e) e$type[1]) == "runs")]]$to), "\n")
shared <- su[su$id %in% names(n_muni)[n_muni > 1], "name"]
cat("Suppliers used by more than one municipality:", paste(shared, collapse = ", "), "\n")
top <- aggregate(from ~ to, fund, length); top <- top[order(-top$from), ][1:10, ]
top$title <- tf_nodes$title[match(top$to, tf_nodes$id)]
top$budget_meur <- round(tf_nodes$budget_2025_keur[match(top$to, tf_nodes$id)] / 1000, 1)
cat("\nTask fields with most systems:\n"); print(top, row.names = FALSE)
message("Wrote ", file.path(out_dir, "nodes.jsonl"), " and edges.jsonl")
