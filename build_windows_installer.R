# =============================================================================
# build_windows_installer.R  (CI‑hardened, always installs RInno from GitHub)
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Install RInno dependencies and RInno itself
# -----------------------------------------------------------------------------
install_rinno_from_github <- function() {
  message("Installing RInno from GitHub (zip download)...")

  # Ensure required dependencies are installed
  deps <- c("installr", "pkgbuild", "remotes")
  missing <- deps[!sapply(deps, requireNamespace, quietly = TRUE)]
  if (length(missing)) {
    message("Installing missing dependencies: ", paste(missing, collapse = ", "))
    install.packages(missing, repos = "https://cloud.r-project.org")
  }

  tmp_zip <- tempfile(fileext = ".zip")
  tmp_dir <- tempfile()
  dir.create(tmp_dir)

  branches <- c("master", "main")
  downloaded <- FALSE
  for (b in branches) {
    url <- sprintf("https://github.com/ficonsulting/RInno/archive/refs/heads/%s.zip", b)
    ok <- tryCatch({
      download.file(url, tmp_zip, mode = "wb", quiet = FALSE)  # be verbose
      file.exists(tmp_zip) && file.info(tmp_zip)$size > 1000
    }, error = function(e) { message("Download error: ", e$message); FALSE },
       warning = function(w) { message("Download warning: ", w$message); FALSE })
    if (isTRUE(ok)) { downloaded <- TRUE; break }
  }

  if (!downloaded) {
    stop("Could not download RInno from GitHub. Check internet or manual fallback.")
  }

  unzip(tmp_zip, exdir = tmp_dir)
  pkg_folder <- list.dirs(tmp_dir, recursive = FALSE)[1]
  message("Installing RInno from: ", pkg_folder)
  install.packages(pkg_folder, repos = NULL, type = "source")
}

# Always install RInno (overwrites any existing)
message("Ensuring RInno is installed...")
# Remove any existing RInno to avoid conflicts
if ("RInno" %in% installed.packages()[, "Package"]) {
  message("Removing existing RInno package...")
  remove.packages("RInno")
}
install_rinnno_from_github()

# Verify installation
if (!requireNamespace("RInno", quietly = TRUE)) {
  stop("RInno installation failed. Check previous messages.")
}
library(RInno)

# -----------------------------------------------------------------------------
# 2. Auto‑detect script directory and app file (unchanged)
# -----------------------------------------------------------------------------
get_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg))))
  }
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    ctx <- tryCatch(rstudioapi::getActiveDocumentContext(), error = function(e) NULL)
    if (!is.null(ctx) && nchar(ctx$path) > 0) return(dirname(ctx$path))
  }
  getwd()
}

APP_DIR <- get_script_dir()
message("Working directory: ", APP_DIR)
setwd(APP_DIR)

all_r_files <- list.files(APP_DIR, pattern = "\\.R$", full.names = FALSE)
candidates  <- setdiff(all_r_files, "build_windows_installer.R")

if (length(candidates) == 0) {
  stop("No .R file found (other than this script). Put your app .R file here.")
} else if (length(candidates) == 1) {
  source_file <- candidates[1]
} else {
  app_like <- candidates[grepl("app", candidates, ignore.case = TRUE)]
  source_file <- if (length(app_like) >= 1) app_like[1] else candidates[1]
  message("Multiple .R files: ", paste(candidates, collapse = ", "))
  message("Using: ", source_file)
}

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
# 3. Configuration
# -----------------------------------------------------------------------------
APP_NAME    <- "Plant Identification AI"
APP_VERSION <- "1.0.0"
PUBLISHER   <- "Your Name / Org"
R_VER <- paste(R.version$major, strsplit(R.version$minor, "\\.")[[1]][1], sep = ".")
message("R version: ", R_VER)

PACKAGES <- c(
  "shiny", "bslib", "DT", "DBI", "RSQLite", "magick", "base64enc",
  "httr", "jsonlite", "torch", "torchvision", "ggplot2", "plotly",
  "shinycssloaders", "shinytoastr", "digest"
)

# -----------------------------------------------------------------------------
# 4. Create the Inno Setup script
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
  stop("RInno did not generate .iss file. Check create_app() errors.")
}

# -----------------------------------------------------------------------------
# 5. Inject post‑install step for libtorch
# -----------------------------------------------------------------------------
iss_lines <- readLines(iss_path)
run_section_idx <- grep("^\\[Run\\]", iss_lines)

torch_install_line <- paste0(
  'Filename: "{app}\\R-Portable\\bin\\Rscript.exe"; ',
  'Parameters: "-e ""torch::install_torch()"""; ',
  'StatusMsg: "Downloading neural network engine (libtorch) – needs internet..."; ',
  'Flags: runhidden waituntilterminated'
)

if (length(run_section_idx) > 0) {
  iss_lines <- append(iss_lines, torch_install_line, after = run_section_idx[1])
} else {
  iss_lines <- c(iss_lines, "[Run]", torch_install_line)
}
writeLines(iss_lines, iss_path)

# -----------------------------------------------------------------------------
# 6. Compile the installer
# -----------------------------------------------------------------------------
# Ensure Inno Setup compiler is in PATH
if (nchar(Sys.which("iscc")) == 0) {
  paths <- c("C:/Program Files (x86)/Inno Setup 6",
             "C:/Program Files/Inno Setup 6")
  for (p in paths) {
    if (file.exists(file.path(p, "iscc.exe"))) {
      Sys.setenv(PATH = paste(p, Sys.getenv("PATH"), sep = ";"))
      break
    }
  }
}
if (nchar(Sys.which("iscc")) == 0) {
  stop("Inno Setup compiler (iscc.exe) not found. Please install Inno Setup.")
}

compile_iss(iss_path = iss_path)

message("\n==============================================")
message("Build complete: installer_output/", APP_NAME, "_", APP_VERSION, ".exe")
message("First install needs internet (downloads libtorch).")
message("==============================================")
