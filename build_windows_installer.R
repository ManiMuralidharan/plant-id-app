# =============================================================================
# build_windows_installer.R
#
# Builds app_fixed.R into a Windows installer (.exe) using RInno.
# Run this on WINDOWS, in the same folder as app_fixed.R.
#
# IMPORTANT — read this before running:
#   {torch} is not a normal CRAN package. The R package itself is small, but
#   the actual neural-network engine (libtorch, ~500MB-1GB) is downloaded
#   SEPARATELY the first time torch::install_torch() runs. RInno's `pkgs`
#   argument only installs the R package, not libtorch. This script adds a
#   post-install step that runs install_torch() automatically — but it means
#   end users need an internet connection during the FIRST installation
#   (not during normal use afterwards).
#
#   If you'd rather avoid that entirely, see the note at the bottom of this
#   file about switching to a lighter inference backend.
# =============================================================================

if (!requireNamespace("RInno", quietly = TRUE)) {
  # FIXED: no remotes/install_github/install_url here at all — those can
  # shell out to Git even for a "plain zip" download in some code paths,
  # which is what kept reproducing the "Git does not seem to be installed"
  # error. This downloads the zip with base R's download.file(), unzips it,
  # and installs from the local folder — zero Git dependency anywhere.
  message("Installing RInno (no Git required)...")

  tmp_zip <- tempfile(fileext = ".zip")
  tmp_dir <- tempfile()
  dir.create(tmp_dir)

  # GitHub's default branch name varies by repo (master vs main), so try both.
  branches   <- c("master", "main")
  downloaded <- FALSE
  for (b in branches) {
    url <- sprintf("https://github.com/ficonsulting/RInno/archive/refs/heads/%s.zip", b)
    ok <- tryCatch({
      download.file(url, tmp_zip, mode = "wb", quiet = TRUE)
      file.exists(tmp_zip) && file.info(tmp_zip)$size > 1000
    }, error = function(e) FALSE, warning = function(w) FALSE)
    if (isTRUE(ok)) { downloaded <- TRUE; break }
  }

  if (!downloaded) {
    stop(
      "Could not download RInno automatically.\n",
      "Manual fallback:\n",
      "  1. Open https://github.com/ficonsulting/RInno in a browser\n",
      "  2. Click Code -> Download ZIP\n",
      "  3. Unzip it, then in R run:\n",
      "     install.packages('C:/path/to/unzipped/RInno-folder', repos = NULL, type = 'source')"
    )
  }

  unzip(tmp_zip, exdir = tmp_dir)
  pkg_folder <- list.dirs(tmp_dir, recursive = FALSE)[1]
  install.packages(pkg_folder, repos = NULL, type = "source")
}
library(RInno)

# ── Auto-detect everything instead of hardcoding paths/filenames ─────────────
# This avoids the #1 cause of build failures: the script expecting an exact
# filename ("app_fixed.R") when your downloaded copy might actually be named
# something like "app fixed (1).R" (browsers add "(1)" automatically when a
# file of that name already exists in your Downloads folder).

get_script_dir <- function() {
  # Works whether run via Rscript, source(), or RStudio's Source button
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) > 0) return(dirname(normalizePath(sub("^--file=", "", file_arg))))
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    ctx <- tryCatch(rstudioapi::getActiveDocumentContext(), error = function(e) NULL)
    if (!is.null(ctx) && nchar(ctx$path) > 0) return(dirname(ctx$path))
  }
  getwd()
}

APP_DIR <- get_script_dir()
message("Working directory detected as: ", APP_DIR)

# Find the Shiny app file: any .R file in this folder that isn't this script
# itself.
all_r_files <- list.files(APP_DIR, pattern = "\\.R$", full.names = FALSE)
candidates  <- setdiff(all_r_files, "build_windows_installer.R")

if (length(candidates) == 0) {
  stop("No .R file found in ", APP_DIR, " other than this build script.\n",
       "Make sure your Shiny app file is in the same folder, then try again.")
} else if (length(candidates) == 1) {
  source_file <- candidates[1]
} else {
  # Prefer a file with "app" in the name if there are multiple candidates
  app_like <- candidates[grepl("app", candidates, ignore.case = TRUE)]
  source_file <- if (length(app_like) >= 1) app_like[1] else candidates[1]
  message("Multiple .R files found: ", paste(candidates, collapse = ", "))
  message("Using: ", source_file, "  (edit `source_file` below if this is wrong)")
}
message("App file detected as: ", source_file)

# Copy to a clean filename — RInno/Inno Setup can choke on spaces and
# parentheses in filenames (e.g. "app fixed (1).R"), so we sidestep that
# entirely by working from a clean copy called app.R.
clean_path <- file.path(APP_DIR, "app.R")
if (normalizePath(file.path(APP_DIR, source_file)) != normalizePath(clean_path, mustWork = FALSE)) {
  file.copy(file.path(APP_DIR, source_file), clean_path, overwrite = TRUE)
  message("Copied to clean filename: app.R")
}

APP_NAME    <- "Plant Identification AI"
APP_VERSION <- "1.0.0"
PUBLISHER   <- "Your Name / Org"

# Auto-detect installed R version instead of hardcoding — avoids a mismatch
# error if your Windows R install differs from what this script assumed.
R_VER <- paste(R.version$major, strsplit(R.version$minor, "\\.")[[1]][1], sep = ".")
message("R version detected as: ", R_VER)

PACKAGES <- c(
  "shiny", "bslib", "DT", "DBI", "RSQLite", "magick", "base64enc",
  "httr", "jsonlite", "torch", "torchvision", "ggplot2", "plotly",
  "shinycssloaders", "shinytoastr", "digest"
)

create_app(
  app_name    = APP_NAME,
  app_dir     = APP_DIR,
  dir_out     = "installer_output",
  include_R   = TRUE,
  R_version   = R_VER,
  pkgs        = PACKAGES,
  remotes     = character(0),
  publisher   = PUBLISHER,
  app_version = APP_VERSION,
  default_dir = "userpf",
  privilege   = "lowest",
  main        = "app.R"
)

iss_path <- file.path("installer_output", paste0(APP_NAME, ".iss"))

# ── Inject a post-install step that downloads libtorch ───────────────────────
# RInno doesn't expose this natively, so we append a [Run] entry directly to
# the generated .iss file before compiling. This runs AFTER R + packages are
# installed, using the bundled Rscript.exe.
iss_lines <- readLines(iss_path)
run_section_idx <- grep("^\\[Run\\]", iss_lines)

torch_install_line <- paste0(
  'Filename: "{app}\\R-Portable\\bin\\Rscript.exe"; ',
  'Parameters: "-e ""torch::install_torch()"""; ',
  'StatusMsg: "Downloading the neural network engine (libtorch) - this needs internet and a few minutes..."; ',
  'Flags: runhidden waituntilterminated'
)

if (length(run_section_idx) > 0) {
  iss_lines <- append(iss_lines, torch_install_line, after = run_section_idx[1])
} else {
  iss_lines <- c(iss_lines, "[Run]", torch_install_line)
}
writeLines(iss_lines, iss_path)

compile_iss(iss_path = iss_path)

message("\n==============================================")
message("Build complete: installer_output/", APP_NAME, "_", APP_VERSION, ".exe")
message("First install will need internet access (downloads libtorch).")
message("==============================================")

# =============================================================================
# ALTERNATIVE — avoid the libtorch download entirely
# =============================================================================
# If you'd rather ship a smaller, fully self-contained installer with no
# first-run download requirement, the two practical options are:
#
#   A) Swap {torch}/{torchvision} for {keras}/{tensorflow} — same trade-off
#      exists there too (TensorFlow also downloads a backend), OR
#
#   B) Pre-extract embeddings on YOUR machine for every species you add,
#      ship the SQLite file with the installer, and run inference through a
#      lightweight ONNX model (~30MB, no separate download) instead of full
#      PyTorch via {torch}. This requires exporting your ResNet-50 to ONNX
#      once and using the {onnxruntime} R package for extract_embedding().
#
# Both are larger changes — happy to build either one out if you want it.
# =============================================================================
