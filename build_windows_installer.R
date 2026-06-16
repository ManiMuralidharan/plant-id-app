# =============================================================================
# build_windows_installer.R – RELIABLE VERSION (fixed R version)
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Install RInno from GitHub
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 2. Fix the HTML scraping bug in RInno for R 4.x
# -----------------------------------------------------------------------------
message("Applying RInno HTML scraping patch...")
for (f in c("code_section", "get_R")) {
  fn <- getFromNamespace(f, "RInno")
  b <- deparse(body(fn))
  
  # 1. Update the hardcoded regex to support modern R versions
  b <- gsub("\\[1-3\\]", "[1-9]", b)
  
  # 2. Fix the length zero crash by forcing a safe TRUE/FALSE evaluation
  b <- gsub("latest_R_version == R_version", "isTRUE(latest_R_version[1] == R_version)", b)
  
  # Reassemble and inject back into the RInno package memory
  body(fn) <- as.call(parse(text = paste(b, collapse = "\n"))[[1]])
  assignInNamespace(f, fn, ns = "RInno")
}

# -----------------------------------------------------------------------------
# 3. Setup directories and locate app.R
# -----------------------------------------------------------------------------
APP_DIR <- Sys.getenv("GITHUB_WORKSPACE", unset = getwd())
setwd(APP_DIR)
message("Working directory: ", APP_DIR)

all_r_files <- list.files(APP_DIR, pattern = "\\.R$", full.names = TRUE, recursive = TRUE)
candidates <- all_r_files[!grepl("build_windows_installer\\.R$", all_r_files)]

if (length(candidates) == 0) {
  stop("No .R file found.")
} else {
  source_file <- candidates[1]
  message("Found app file: ", source_file)
  target_file <- file.path(APP_DIR, "app.R")
  if (normalizePath(source_file, winslash = "/", mustWork = FALSE) !=
      normalizePath(target_file, winslash = "/", mustWork = FALSE)) {
    file.copy(source_file, target_file, overwrite = TRUE)
    message("Copied to app.R in root.")
  } else {
    message("app.R already in root.")
  }
}

# -----------------------------------------------------------------------------
# 4. Configuration – USE A KNOWN STABLE R VERSION
# -----------------------------------------------------------------------------
APP_NAME    <- "Plant Identification AI"
APP_VERSION <- "1.0.0"

# Use a version that definitely exists on CRAN
R_VER <- "4.4.0" 
message("Bundling R version: ", R_VER)

PACKAGES <- c("shiny", "bslib", "DT", "DBI", "RSQLite", "magick", "base64enc",
              "httr", "jsonlite", "torch", "torchvision", "ggplot2", "plotly",
              "shinycssloaders", "shinytoastr", "digest")

# -----------------------------------------------------------------------------
# 5. Create Inno Setup script
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# 6. Inject post-install libtorch download into the .iss file
# -----------------------------------------------------------------------------
iss_files <- list.files("installer_output", pattern = "\\.iss$", full.names = TRUE)
if (length(iss_files) == 0) {
  stop("Could not find any .iss file generated! Check create_app output.")
}
iss_path <- iss_files[1]
message("Found .iss file: ", iss_path)

iss_lines <- readLines(iss_path)
run_idx <- grep("^\\[Run\\]", iss_lines)
torch_line <- 'Filename: "{app}\\R-Portable\\bin\\Rscript.exe"; Parameters: "-e ""torch::install_torch()"""; StatusMsg: "Downloading neural network engine..."; Flags: runhidden waituntilterminated'

if (length(run_idx) > 0) {
  iss_lines <- append(iss_lines, torch_line, after = run_idx[1])
} else {
  iss_lines <- c(iss_lines, "[Run]", torch_line)
}
writeLines(iss_lines, iss_path)

# -----------------------------------------------------------------------------
# 7. Compile the installer
# -----------------------------------------------------------------------------
if (nchar(Sys.which("iscc")) == 0) {
  Sys.setenv(PATH = paste("C:/Program Files (x86)/Inno Setup 6", Sys.getenv("PATH"), sep = ";"))
}
compile_iss(iss_path = iss_path)

message("\n==============================================")
message("Build complete: installer_output/", APP_NAME, "_", APP_VERSION, ".exe")
message("==============================================")
