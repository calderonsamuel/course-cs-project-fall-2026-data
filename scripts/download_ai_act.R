# Download the AI Act, Regulation (EU) 2024/1689 (CELEX 32024R1689), from
# EUR-Lex / Cellar in structured formats.
#
# eurlex is used for the title check and the metadata notice. It cannot fetch
# the text in a structured form (elx_fetch_data(type = "text") strips HTML to
# plain text), so the Formex and XHTML manifestations are requested from Cellar
# directly with httr2 content negotiation.
#
# Outputs (in data/raw/ai_act/):
#   fmx4/                       Formex 4 XML files (main act, annexes, doc descriptor)
#   32024R1689_fmx4.zip         the zip as received from Cellar
#   32024R1689_en.xhtml         XHTML rendering (fallback/cross-check for Formex)
#   32024R1689_notice_tree.xml  Cellar metadata notice ("tree" level)
#   32024R1689_manifest.json    provenance and sanity-check results
#
# Run from the project root:  Rscript scripts/download_ai_act.R

celex    <- "32024R1689"
lang     <- "en"
lang3    <- "eng"   # Cellar uses ISO 639-2 codes for Accept-Language
cellar   <- paste0("http://publications.europa.eu/resource/celex/", celex)
out_dir  <- file.path("data", "raw", "ai_act")

# Expected structure of the OJ version, used for sanity checks.
expected <- list(recitals = 180, articles = 113, annexes = 13)

# --- 0. Preconditions --------------------------------------------------------

for (p in c("eurlex", "httr2", "xml2", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Package '", p, "' is required.")
}
eurlex_version <- as.character(packageVersion("eurlex"))
message("eurlex version: ", eurlex_version)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
fmx_dir     <- file.path(out_dir, "fmx4")
fmx_zip     <- file.path(out_dir, paste0(celex, "_fmx4.zip"))
xhtml_file  <- file.path(out_dir, paste0(celex, "_", lang, ".xhtml"))
notice_file <- file.path(out_dir, paste0(celex, "_notice_tree.xml"))
manifest    <- file.path(out_dir, paste0(celex, "_manifest.json"))

# GET a Cellar resource with content negotiation and write the body to disk.
# HTTP errors are returned, not thrown, so the caller can fall back.
# Returns the httr2 response; a 300 (several items) is resolved to its first link.
cellar_get <- function(url, accept, dest) {
  fetch <- function(u) {
    httr2::request(u) |>
      httr2::req_headers(Accept = accept, `Accept-Language` = lang3) |>
      httr2::req_timeout(120) |>
      httr2::req_retry(max_tries = 3) |>
      httr2::req_error(is_error = function(resp) FALSE) |>
      httr2::req_perform(path = dest)
  }
  resp <- fetch(url)
  if (httr2::resp_status(resp) == 300) {
    links <- xml2::xml_attr(xml2::xml_find_all(xml2::read_html(dest), "//a"), "href")
    message("  300 Multiple Choices for ", accept, "; ", length(links),
            " items, taking the first: ", links[1])
    resp <- fetch(links[1])
  }
  message("  ", accept, " -> HTTP ", httr2::resp_status(resp), ", ",
          file.size(dest), " bytes, final URL ", httr2::resp_url(resp))
  resp
}

# --- 1. Title (small request, confirms the CELEX resolves) -------------------

title <- eurlex::elx_fetch_data(url = cellar, type = "title", language_1 = lang)
if (length(title) == 0 || is.na(title[1]) ||
    !grepl("artificial intelligence", title[1], ignore.case = TRUE)) {
  stop("Title lookup did not return the AI Act. Got: ", paste(title, collapse = " | "))
}
message("Title: ", substr(title[1], 1, 120), "...")

# --- 2. Metadata notice ------------------------------------------------------
# Contains dates, EuroVoc terms, relations (proposal, amendments, consolidated
# versions) and the list of available manifestations.

eurlex::elx_download_xml(url = cellar, file = notice_file, notice = "tree", language_1 = lang)
notice <- xml2::read_xml(notice_file)
manifestation_types <- sort(unique(xml2::xml_text(
  xml2::xml_find_all(notice, "//MANIFESTATION_TYPE/VALUE"))))
message("Manifestations listed in notice: ", paste(manifestation_types, collapse = ", "))

# --- 3. Formex 4 (primary structured source) ---------------------------------

message("Requesting Formex 4 ...")
fmx_resp <- cellar_get(cellar, "application/zip;mtype=fmx4", fmx_zip)
fmx_ok   <- httr2::resp_status(fmx_resp) == 200
fmx_files <- character(0)
if (fmx_ok) {
  unlink(fmx_dir, recursive = TRUE)
  fmx_files <- utils::unzip(fmx_zip, exdir = fmx_dir)
  message("  unzipped ", length(fmx_files), " files into ", fmx_dir)
} else {
  warning("Formex not retrieved (HTTP ", httr2::resp_status(fmx_resp), "); relying on XHTML.")
}

# --- 4. XHTML (fallback and cross-check) --------------------------------------

message("Requesting XHTML ...")
xhtml_resp <- cellar_get(cellar, "application/xhtml+xml", xhtml_file)
xhtml_ok   <- httr2::resp_status(xhtml_resp) == 200
if (!fmx_ok && !xhtml_ok) stop("Neither Formex nor XHTML could be retrieved.")

# --- 5. Sanity checks --------------------------------------------------------

count_fmx <- function(xpath) {
  xml_files <- fmx_files[grepl("\\.xml$", fmx_files)]
  sum(vapply(xml_files, function(f) {
    length(xml2::xml_find_all(xml2::read_xml(f), xpath))
  }, integer(1)))
}
fmx_counts <- if (fmx_ok) list(
  recitals = count_fmx("//CONSID"),
  articles = count_fmx("//ARTICLE"),
  annexes  = count_fmx("//ANNEX")
) else NULL

# EUR-Lex XHTML for recent acts marks subdivisions with ids like rct_1, art_1, anx_I.
xhtml_counts <- if (xhtml_ok) {
  ids <- xml2::xml_attr(xml2::xml_find_all(xml2::read_html(xhtml_file), "//*[@id]"), "id")
  list(recitals = sum(grepl("^rct_\\d+$", ids)),
       articles = sum(grepl("^art_\\d+$", ids)),
       annexes  = sum(grepl("^anx_[IVXLC]+$", ids)))
} else NULL

matches <- function(counts) {
  if (is.null(counts)) return(NULL)
  setNames(lapply(names(expected), function(k) counts[[k]] == expected[[k]]), names(expected))
}

# --- 6. Manifest -------------------------------------------------------------

file_info <- function(path) list(file = basename(path), bytes = file.size(path),
                                 md5 = unname(tools::md5sum(path)))

info <- list(
  celex          = celex,
  eli            = "http://data.europa.eu/eli/reg/2024/1689/oj",
  cellar_url     = cellar,
  language       = lang,
  title          = title[1],
  retrieved_at   = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  eurlex_version = eurlex_version,
  r_version      = R.version.string,
  notice = c(file_info(notice_file), list(level = "tree",
                                          manifestation_types = manifestation_types)),
  fmx4 = list(
    retrieved  = fmx_ok,
    http_status = httr2::resp_status(fmx_resp),
    source_url = httr2::resp_url(fmx_resp),
    zip        = if (fmx_ok) file_info(fmx_zip) else NULL,
    files      = if (fmx_ok) lapply(fmx_files, function(f)
                   c(file_info(f), list(root = xml2::xml_name(xml2::read_xml(f))))) else list(),
    counts     = fmx_counts,
    counts_match_expected = matches(fmx_counts)
  ),
  xhtml = list(
    retrieved  = xhtml_ok,
    http_status = httr2::resp_status(xhtml_resp),
    source_url = httr2::resp_url(xhtml_resp),
    file       = if (xhtml_ok) file_info(xhtml_file) else NULL,
    counts     = xhtml_counts,
    counts_match_expected = matches(xhtml_counts)
  ),
  expected = expected
)
jsonlite::write_json(info, manifest, auto_unbox = TRUE, pretty = TRUE, null = "null")
message("Wrote ", manifest)

for (src in c("fmx4", "xhtml")) {
  m <- info[[src]]$counts_match_expected
  if (!is.null(m) && !all(unlist(m))) {
    warning(src, " counts differ from expected: ",
            paste(sprintf("%s=%d", names(info[[src]]$counts), unlist(info[[src]]$counts)),
                  collapse = ", "))
  }
}
