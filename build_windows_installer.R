# -----------------------------------------------------------------------------
# 1. Install RInno – with CRAN fallback to GitHub zip (no Git needed)
# -----------------------------------------------------------------------------
if (!requireNamespace("RInno", quietly = TRUE)) {
  message("Attempting to install RInno from CRAN...")
  tryCatch({
    install.packages("RInno", repos = "https://cloud.r-project.org")
  }, error = function(e) { message("CRAN install failed: ", e$message) })

  # If still not installed, fallback to GitHub zip download
  if (!requireNamespace("RInno", quietly = TRUE)) {
    message("Falling back to GitHub download (zip, no Git required)...")
    tmp_zip <- tempfile(fileext = ".zip")
    tmp_dir <- tempfile()
    dir.create(tmp_dir)

    # Try both possible default branches (master/main)
    branches <- c("master", "main")
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
}
library(RInno)

# -----------------------------------------------------------------------------
# 2. Helper: get the directory where this script is located
# -----------------------------------------------------------------------------
get_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg))))
  }
  # Fallback for RStudio / interactive
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    ctx <- tryCatch(rstudioapi::getActiveDocumentContext(), error = function(e) NULL)
    if (!is.null(ctx) && nchar(ctx$path) > 0) return(dirname(ctx$path))
  }
  getwd()
}

APP_DIR <- get_script_dir()
message("Working directory: ", APP_DIR)
setwd(APP_DIR)  # ensure consistency

# -----------------------------------------------------------------------------
# 3. Locate the Shiny app file (any .R except this script)
# -----------------------------------------------------------------------------
all_r_files <- list.files(APP_DIR, pattern = "\\.R$", full.names = FALSE)
candidates  <- setdiff(all_r_files, "build_windows_installer.R")

if (length(candidates) == 0) {
  stop("No .R file found other than this build script. Put your app .R file in the same folder.")
} else if (length(candidates) == 1) {
  source_file <- candidates[1]
} else {
  # Prefer files with "app" in the name
  app_like <- candidates[grepl("app", candidates, ignore.case = TRUE)]
  source_file <- if (length(app_like) >= 1) app_like[1] else candidates[1]
  message("Multiple .R files: ", paste(candidates, collapse = ", "))
  message("Using: ", source_file)
}

# Copy to a clean `app.R` (no spaces, parentheses, etc.)
clean_path <- file.path(APP_DIR, "app.R")
if (normalizePath(file.path(APP_DIR, source_file), mustWork = FALSE) !=
    normalizePath(clean_path, mustWork = FALSE)) {
  file.copy(file.path(APP_DIR, source_file), clean_path, overwrite = TRUE)
  message("Copied to clean filename: app.R")
}
if (!file.exists("app.R")) {
  stop("Failed to create app.R. Check file permissions.")
}

# -----------------------------------------------------------------------------
# 4. Configuration
# -----------------------------------------------------------------------------
APP_NAME    <- "Plant Identification AI"
APP_VERSION <- "1.0.0"
PUBLISHER   <- "Your Name / Org"
R_VER <- paste(R.version$major, strsplit(R.version$minor, "\\.")[[1]][1], sep = ".")
message("Detected R version: ", R_VER)

PACKAGES <- c(
  "shiny", "bslib", "DT", "DBI", "RSQLite", "magick", "base64enc",
  "httr", "jsonlite", "torch", "torchvision", "ggplot2", "plotly",
  "shinycssloaders", "shinytoastr", "digest"
)

# -----------------------------------------------------------------------------
# 5. Create the Inno Setup script (.iss) via RInno
# -----------------------------------------------------------------------------
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
if (!file.exists(iss_path)) {
  stop("RInno did not generate the .iss file. Check create_app() errors.")
}

# -----------------------------------------------------------------------------
# 6. Inject post‑install step to download libtorch
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 7. Compile the installer
# -----------------------------------------------------------------------------
# Check that Inno Setup is available (ISCC.exe in PATH)
iscc_available <- nchar(Sys.which("iscc")) > 0
if (!iscc_available) {
  # Try common install location
  possible_paths <- c(
    "C:/Program Files (x86)/Inno Setup 6/iscc.exe",
    "C:/Program Files/Inno Setup 6/iscc.exe"
  )
  for (p in possible_paths) {
    if (file.exists(p)) {
      Sys.setenv(PATH = paste(dirname(p), Sys.getenv("PATH"), sep = ";"))
      iscc_available <- TRUE
      break
    }
  }
}
if (!iscc_available) {
  stop("Inno Setup compiler (iscc.exe) not found. Please install Inno Setup and add it to PATH.")
}

# Compile
compile_iss(iss_path = iss_path)

message("\n==============================================")
message("Build complete: installer_output/", APP_NAME, "_", APP_VERSION, ".exe")
message("First install will need internet access (downloads libtorch).")
message("==============================================")
