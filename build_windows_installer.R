# =============================================================================
# build_windows_installer.R
# =============================================================================

# 1. Install RInno dependencies and RInno itself
install_rinno_from_github <- function() {
  message("Installing RInno from GitHub...")

  deps <- c("installr", "pkgbuild", "remotes")
  missing <- deps[!sapply(deps, requireNamespace, quietly = TRUE)]
  if (length(missing)) {
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
      download.file(url, tmp_zip, mode = "wb", quiet = TRUE)
      file.exists(tmp_zip) && file.info(tmp_zip)$size > 1000
    }, error = function(e) FALSE)
    if (isTRUE(ok)) { downloaded <- TRUE; break }
  }

  if (!downloaded) stop("Could not download RInno.")

  unzip(tmp_zip, exdir = tmp_dir)
  pkg_folder <- list.dirs(tmp_dir, recursive = FALSE)[1]
  install.packages(pkg_folder, repos = NULL, type = "source")
}

# Ensure RInno is installed
if ("RInno" %in% installed.packages()[, "Package"]) remove.packages("RInno")
install_rinno_from_github()
library(RInno)

# 2. Setup Directories
get_script_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) > 0) return(dirname(normalizePath(sub("^--file=", "", file_arg))))
  getwd()
}

# Use the environment variable set by GitHub Actions
# or fall back to the current working directory
APP_DIR <- Sys.getenv("GITHUB_WORKSPACE", unset = getwd())
setwd(APP_DIR)

message("Working directory set to: ", APP_DIR)
message("Searching for app files in: ", APP_DIR)

# Debug: List all files to verify
files_found <- list.files(APP_DIR, pattern = "\\.R$", full.names = FALSE)
message("Found R files: ", paste(files_found, collapse = ", "))

candidates <- setdiff(files_found, "build_windows_installer.R")

if (length(candidates) == 0) {
  stop("No .R file found. Files present: ", paste(list.files(APP_DIR), collapse = ", "))
}

# Ensure app.R exists
all_r_files <- list.files(APP_DIR, pattern = "\\.R$", full.names = FALSE)
candidates <- setdiff(all_r_files, "build_windows_installer.R")
source_file <- if (length(candidates) >= 1) candidates[1] else stop("No .R file found.")
file.copy(file.path(APP_DIR, source_file), file.path(APP_DIR, "app.R"), overwrite = TRUE)

# 3. Configuration
APP_NAME    <- "Plant Identification AI"
APP_VERSION <- "1.0.0"
R_VER       <- paste(R.version$major, strsplit(R.version$minor, "\\.")[[1]][1], sep = ".")
PACKAGES    <- c("shiny", "bslib", "DT", "DBI", "RSQLite", "magick", "base64enc",
                 "httr", "jsonlite", "torch", "torchvision", "ggplot2", "plotly",
                 "shinycssloaders", "shinytoastr", "digest")

# 4. Create Inno Setup script
create_app(
  app_name    = APP_NAME,
  app_dir     = APP_DIR,
  dir_out     = "installer_output",
  include_R   = TRUE,
  R_version   = R_VER,
  pkgs        = PACKAGES,
  publisher   = "Your Name / Org",
  app_version = APP_VERSION,
  main        = "app.R"
)

# 5. Inject post-install libtorch download
iss_path <- file.path("installer_output", paste0(APP_NAME, ".iss"))
iss_lines <- readLines(iss_path)
run_idx <- grep("^\\[Run\\]", iss_lines)
torch_line <- 'Filename: "{app}\\R-Portable\\bin\\Rscript.exe"; Parameters: "-e ""torch::install_torch()"""; StatusMsg: "Downloading neural network engine..."; Flags: runhidden waituntilterminated'

if (length(run_idx) > 0) {
  iss_lines <- append(iss_lines, torch_line, after = run_idx[1])
} else {
  iss_lines <- c(iss_lines, "[Run]", torch_line)
}
writeLines(iss_lines, iss_path)

# 6. Compile
if (nchar(Sys.which("iscc")) == 0) {
  Sys.setenv(PATH = paste("C:/Program Files (x86)/Inno Setup 6", Sys.getenv("PATH"), sep = ";"))
}
compile_iss(iss_path = iss_path)

message("\n==============================================")
message("Build complete: installer_output/", APP_NAME, "_", APP_VERSION, ".exe")
message("First install needs internet (downloads libtorch).")
message("==============================================")
