# Download the English XHTML of a Commission proposal from Cellar.
# Proposals have no Formex manifestation, so XHTML is the most structured format.
# A proposal and its annexes can be separate items in one manifestation; Cellar
# then answers 300 Multiple Choices and every listed item is saved.
#
# Outputs (in data/raw/proposals/<CELEX>/):
#   <CELEX>_en_<n>.xhtml   one file per item, in the order Cellar lists them
#                          (for 52021PC0206: 1 = main text, 2 = annexes; see manifest for DOC_n URLs)
#   <CELEX>_manifest.json  provenance
#
# Usage from the project root:  Rscript scripts/download_proposal_xhtml.R 52021PC0206

args  <- commandArgs(trailingOnly = TRUE)
celex <- if (length(args)) args[1] else "52021PC0206"
lang3 <- "eng"
cellar  <- paste0("http://publications.europa.eu/resource/celex/", celex)
out_dir <- file.path("data", "raw", "proposals", celex)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

fetch <- function(url, dest) {
  httr2::request(url) |>
    httr2::req_headers(Accept = "application/xhtml+xml", `Accept-Language` = lang3) |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform(path = dest)
}

first <- file.path(out_dir, paste0(celex, "_en_1.xhtml"))
resp  <- fetch(cellar, first)
status <- httr2::resp_status(resp)
message(celex, " -> HTTP ", status, ", final URL ", httr2::resp_url(resp))

items <- list()
if (status == 200) {
  items[[1]] <- list(url = httr2::resp_url(resp), file = first)
} else if (status == 300) {
  links <- xml2::xml_attr(xml2::xml_find_all(xml2::read_html(first), "//a"), "href")
  message("  300 Multiple Choices: ", length(links), " items")
  for (i in seq_along(links)) {
    dest <- file.path(out_dir, paste0(celex, "_en_", i, ".xhtml"))
    r <- fetch(links[i], dest)
    message("  item ", i, ": HTTP ", httr2::resp_status(r), ", ", file.size(dest), " bytes, ", links[i])
    if (httr2::resp_status(r) == 200) items[[length(items) + 1]] <- list(url = links[i], file = dest)
  }
} else {
  stop("Unexpected HTTP status ", status)
}

info <- list(
  celex        = celex,
  cellar_url   = cellar,
  language     = lang3,
  retrieved_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  items = lapply(items, function(it) list(
    file = basename(it$file), source_url = it$url,
    bytes = file.size(it$file), md5 = unname(tools::md5sum(it$file))))
)
jsonlite::write_json(info, file.path(out_dir, paste0(celex, "_manifest.json")),
                     auto_unbox = TRUE, pretty = TRUE)
message("Saved ", length(items), " item(s) in ", out_dir)
