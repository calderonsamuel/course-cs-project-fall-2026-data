# Download the Dutch national algorithm register (algoritmes.overheid.nl) as
# CSV: all current algorithm descriptions, and all descriptions with their
# version history. Uses the register's official download endpoints, listed in
# its OpenAPI description (https://algoritmes.overheid.nl/api/openapi.json):
#   GET /api/downloads/{language}?filetype=csv            all current descriptions
#   GET /api/downloads/history/{language}?filetype=csv    all, with version history
#
# Nothing is filtered here; selecting Amsterdam, Den Haag and Terneuzen is the
# next step. The script only reports how many rows each of them has.
#
# Outputs (in data/raw/algorithm_register/):
#   algoritmeregister_NLD_current.csv
#   algoritmeregister_NLD_history.csv
#   algoritmeregister_manifest.json   provenance, columns, row counts
#
# Run from the project root:  Rscript scripts/download_algorithm_register.R

base    <- "https://algoritmes.overheid.nl/api"
lang    <- "NLD"   # the API uses NLD / ENG / FRY, not nl / en / fy
out_dir <- file.path("data", "raw", "algorithm_register")

# Organisation names as they are expected to appear in the register.
municipalities <- c(
  amsterdam = "^gemeente amsterdam$",
  den_haag  = "^gemeente (den haag|'s-gravenhage)$",
  terneuzen = "^gemeente terneuzen$"
)

for (p in c("httr2", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Package '", p, "' is required.")
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

fetch <- function(path, dest) {
  resp <- httr2::request(base) |>
    httr2::req_url_path_append(path) |>
    httr2::req_url_query(filetype = "csv") |>
    httr2::req_user_agent("cs-project-helsinki research script (R httr2)") |>
    httr2::req_timeout(300) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform(path = dest)
  status <- httr2::resp_status(resp)
  type <- httr2::resp_header(resp, "content-type")
  message(path, " -> HTTP ", status, ", ", type, ", ", file.size(dest), " bytes")
  if (status != 200) stop("Download failed for ", path, " (HTTP ", status, ")")
  if (grepl("html", type %||% "", ignore.case = TRUE)) stop("Got HTML instead of CSV for ", path)
  list(url = httr2::resp_url(resp), status = status, content_type = type)
}
`%||%` <- function(a, b) if (is.null(a)) b else a

# Read a CSV without assuming its separator; fields may contain line breaks.
read_register <- function(f) {
  first <- readLines(f, n = 1, encoding = "UTF-8", warn = FALSE)
  sep <- if (lengths(regmatches(first, gregexpr(";", first))) > lengths(regmatches(first, gregexpr(",", first)))) ";" else ","
  df <- utils::read.csv(f, sep = sep, quote = "\"", encoding = "UTF-8", fileEncoding = "UTF-8-BOM",
                        check.names = FALSE, stringsAsFactors = FALSE, na.strings = c("", "NA"))
  attr(df, "sep") <- sep
  df
}

summarise <- function(f, info) {
  df <- read_register(f)
  org_col <- names(df)[tolower(names(df)) %in% c("organisatie", "organisation", "organization")][1]
  counts <- if (is.na(org_col)) NULL else
    lapply(municipalities, function(rx) sum(grepl(rx, tolower(trimws(df[[org_col]]))), na.rm = TRUE))
  message("  ", nrow(df), " rows, ", ncol(df), " columns, separator '", attr(df, "sep"), "'")
  message("  organisation column: ", org_col %||% "NOT FOUND")
  if (!is.null(counts)) message("  rows per municipality: ",
                                paste(names(counts), unlist(counts), sep = "=", collapse = ", "))
  c(info, list(
    file = basename(f), bytes = file.size(f), md5 = unname(tools::md5sum(f)),
    separator = attr(df, "sep"), n_rows = nrow(df), columns = names(df),
    organisation_column = org_col, rows_per_municipality = counts,
    n_organisations = if (is.na(org_col)) NULL else length(unique(df[[org_col]]))
  ))
}

current_file <- file.path(out_dir, paste0("algoritmeregister_", lang, "_current.csv"))
history_file <- file.path(out_dir, paste0("algoritmeregister_", lang, "_history.csv"))

message("Current descriptions ...")
current_info <- fetch(file.path("downloads", lang), current_file)
current <- summarise(current_file, current_info)
message("Descriptions with version history ...")
history_info <- fetch(file.path("downloads", "history", lang), history_file)
history <- summarise(history_file, history_info)

manifest <- list(
  source = "https://algoritmes.overheid.nl",
  api_description = "https://algoritmes.overheid.nl/api/openapi.json",
  language = lang,
  retrieved_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  r_version = R.version.string,
  municipality_patterns = as.list(municipalities),
  current = current,
  history = history
)
jsonlite::write_json(manifest, file.path(out_dir, "algoritmeregister_manifest.json"),
                     auto_unbox = TRUE, pretty = TRUE, null = "null")
message("Wrote manifest to ", file.path(out_dir, "algoritmeregister_manifest.json"))

if (any(unlist(current$rows_per_municipality) == 0)) {
  warning("A municipality has 0 rows in the current file; check the organisation names in the manifest.")
}
