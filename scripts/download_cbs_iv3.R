# Download CBS Iv3 data for 2025 (table 45071NED, "Gemeenten 2025 onbewerkte
# Iv3-data") for the project's municipalities: expenses, income and balance
# items per task field (taakveld) and economic category, for the budget
# (Begroting) and the annual accounts (Jaarrekening).
#
# Source: CBS OData API for third-party data, https://dataderden.cbs.nl/ODataApi/odata/45071NED
# The data are as delivered by the municipalities; CBS does not edit them.
# Amounts are in thousands of euros. Each report type is published twice:
#   k_1ePlaatsing_1  first release, 10 days after the submission deadline
#   k_2ePlaatsing_2  second release, 70 days after, including corrections
# Missing deliveries come back as null.
#
# Outputs (in data/raw/cbs_iv3/):
#   iv3_2025.csv                 one row per municipality x report x task field x category
#   dim_taakveld.csv, dim_categorie.csv, dim_verslagsoort.csv, dim_gemeenten.csv
#   iv3_2025_manifest.json       provenance, row counts, total expenses per report
#
# Run from the project root:  Rscript scripts/download_cbs_iv3.R

base    <- "https://dataderden.cbs.nl/ODataApi/odata/45071NED"
out_dir <- file.path("data", "raw", "cbs_iv3")
municipalities <- c(GM0363 = "Amsterdam", GM0518 = "Den Haag", GM0715 = "Terneuzen")
reports <- c("2025X000" = "Begroting", "2025X005" = "Jaarrekening")
# CBS returns at most 10,000 rows per request and answers HTTP 500 to $skip, so
# paging is not possible. One municipality and report has up to 145 x 80 =
# 11,600 rows; requests are split by category type (expenses L, income B,
# balance Primo/Ultimo) to stay under the cap, and a response that reaches it
# is treated as an error rather than silently truncated.
CAP <- 10000
CATEGORY_GROUPS <- c(expenses = "startswith(Categorie,'L')",
                     income   = "startswith(Categorie,'B')",
                     balance  = "(startswith(Categorie,'Primo') or startswith(Categorie,'Ultimo'))")

for (p in c("httr2", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Package '", p, "' is required.")
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

get_json <- function(path, query = list()) {
  req <- httr2::request(base) |>
    httr2::req_url_path_append(path) |>
    httr2::req_url_query(!!!query) |>
    httr2::req_user_agent("cs-project-helsinki research script (R httr2)") |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 3)
  httr2::resp_body_json(httr2::req_perform(req), simplifyVector = TRUE)$value
}

# --- Dimensions -----------------------------------------------------------------
# Keys are padded with spaces ("GM0363   ", "0.1   "); filters must use the exact key.

dims <- list(
  taakveld    = get_json("TaakveldBalanspost"),
  categorie   = get_json("Categorie"),
  verslagsoort = get_json("Verslagsoort"),
  gemeenten   = get_json("Gemeenten")
)
for (d in names(dims)) {
  x <- dims[[d]][, intersect(c("Key", "Title", "Description"), names(dims[[d]]))]
  x$Key <- trimws(x$Key)
  write.csv(x, file.path(out_dir, paste0("dim_", d, ".csv")), row.names = FALSE, fileEncoding = "UTF-8")
}
gm_keys <- dims$gemeenten$Key[trimws(dims$gemeenten$Key) %in% names(municipalities)]
vs_keys <- dims$verslagsoort$Key[trimws(dims$verslagsoort$Key) %in% names(reports)]
if (length(gm_keys) != length(municipalities)) stop("Not all municipality codes found in the Gemeenten dimension.")
if (length(vs_keys) != length(reports)) stop("Not all report types found in the Verslagsoort dimension.")

# --- Data, per municipality, report and category type -----------------------------------

rows <- list()
for (g in gm_keys) for (v in vs_keys) for (cg in names(CATEGORY_GROUPS)) {
  filter <- sprintf("Gemeenten eq '%s' and Verslagsoort eq '%s' and %s", g, v, CATEGORY_GROUPS[[cg]])
  page <- get_json("TypedDataSet", list(`$filter` = filter, `$top` = CAP))
  if (length(page) && nrow(page) >= CAP) stop("Response reached the ", CAP, "-row cap for ", filter)
  message(trimws(g), " ", trimws(v), " ", cg, ": ", if (length(page)) nrow(page) else 0, " rows")
  if (length(page) && nrow(page)) rows[[length(rows) + 1]] <- page
}
iv3 <- do.call(rbind, rows)
for (k in c("TaakveldBalanspost", "Categorie", "Gemeenten", "Verslagsoort")) iv3[[k]] <- trimws(iv3[[k]])
names(iv3)[names(iv3) == "k_1ePlaatsing_1"] <- "release1_keur"
names(iv3)[names(iv3) == "k_2ePlaatsing_2"] <- "release2_keur"
write.csv(iv3, file.path(out_dir, "iv3_2025.csv"), row.names = FALSE, fileEncoding = "UTF-8")

# --- Checks -----------------------------------------------------------------------
# Total expenses: categories starting with L on task fields 0.1-8.3, excluding
# L7.1 (transfers to reserves), using the second release where present.

value <- ifelse(is.na(iv3$release2_keur), iv3$release1_keur, iv3$release2_keur)
is_taskfield <- grepl("^[0-8]\\.", iv3$TaakveldBalanspost)
is_expense <- grepl("^L", iv3$Categorie) & iv3$Categorie != "L7.1"
summary_rows <- list()
for (g in names(municipalities)) for (v in names(reports)) {
  sel <- iv3$Gemeenten == g & iv3$Verslagsoort == v
  s <- list(
    municipality = municipalities[[g]], code = g, report = reports[[v]], report_key = v,
    rows = sum(sel),
    rows_with_value_release1 = sum(sel & !is.na(iv3$release1_keur)),
    rows_with_value_release2 = sum(sel & !is.na(iv3$release2_keur)),
    total_expenses_keur = sum(value[sel & is_taskfield & is_expense], na.rm = TRUE)
  )
  summary_rows[[length(summary_rows) + 1]] <- s
  message(sprintf("%-10s %-12s rows=%5d  with values r1=%5d r2=%5d  expenses=EUR %s million",
                  s$municipality, s$report, s$rows, s$rows_with_value_release1,
                  s$rows_with_value_release2, format(round(s$total_expenses_keur / 1000), big.mark = ",")))
}

manifest <- list(
  source = base,
  table = "45071NED Gemeenten 2025 onbewerkte Iv3-data",
  retrieved_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  r_version = R.version.string,
  unit = "thousand euro",
  municipalities = as.list(municipalities),
  reports = as.list(reports),
  n_rows = nrow(iv3),
  columns = names(iv3),
  summary = summary_rows
)
jsonlite::write_json(manifest, file.path(out_dir, "iv3_2025_manifest.json"),
                     auto_unbox = TRUE, pretty = TRUE, null = "null")
message("Wrote ", file.path(out_dir, "iv3_2025.csv"), " and manifest")
