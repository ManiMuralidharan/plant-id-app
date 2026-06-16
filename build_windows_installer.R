# =============================================================================
# build_windows_installer.R
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Install RInno dependencies and RInno itself
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
# 1.5 MONKEY-PATCH RInno to fix R 4.x.x CRAN scraping bugs
# -----------------------------------------------------------------------------
message("Applying RInno patches for R 4.x compatibility...")
patch_rinno <- function() {
  # 1. Fix the HTML scraping bug in code_section
  fn_code <- getFromNamespace("code_section", "RInno")
  b <- deparse(body(fn_code))
  b <- gsub("\\[1-3\\]", "[1-9]", b)
  b <- gsub("latest_R_version == R_version", "latest_R_version[1] == R_version", b)
  body(fn_code) <- as.call(parse(text = paste(b, collapse = "\n"))[[1]])
  assignInNamespace("code_section", fn_code, ns = "RInno")
  
  # 2. Entirely replace get_R to fix the 404 download crashes
  fn_getR <- getFromNamespace("get_R", "RInno")
  body(fn_getR) <- quote({
    # STRIP OUT ANY >= OR <= SIGNS THAT RINNO SNEAKS IN
    clean_R_ver <- gsub("[^0-9.]", "", R_version)
    
    exe_name <- paste0("R-", clean_R_ver, "-win.exe")
    url_main <- paste0("https://cloud.r-project.org/bin/windows/base/", exe_name)
    url_archive <- paste0("https://cloud.r-project.org/bin/windows/base/old/", clean_R_ver, "/", exe_name)
    dest <- file.path(app_dir, exe_name)
    
    message("Downloading ", exe_name, " from CRAN...")
    res <- suppressWarnings(download.file(url_main, dest, mode = "wb", quiet = TRUE))
    
    if (res != 0) {
      message("Trying CRAN archive...")
      download.file(url_archive, dest, mode = "wb", quiet = TRUE)
    }
  })
  assignInNamespace("get_R", fn_getR, ns = "RInno")
}
patch_rinno()

# -----------------------------------------------------------------------------
# 2. Setup Directories & Auto-detect app.R
# -----------------------------------------------------------------------------
# Use the environment variable set by GitHub Actions
APP_DIR <- Sys.getenv("GITHUB_WORKSPACE", unset = getwd())
setwd(APP_DIR)

message("Working directory set to: ", APP_DIR)
message("Searching recursively for app files...")

# Search recursively for the app file
all_r_files <- list.files(APP_DIR, pattern = "\\.R$", full.names = TRUE, recursive = TRUE)

# Filter out this build script specifically
candidates <- all_r_files[!grepl("build_windows_installer\\.R$", all_r_files)]

if (length(candidates) == 0) {
  stop("No .R file found in any subdirectory. Files in root: ", paste(list.files(APP_DIR), collapse = ", "))
} else {
  # Use the first one found
  source_file <- candidates[1]
  message("Found app file at: ", source_file)
  
  # Only copy the file if it isn't ALREADY the target app.R file
  target_file <- file.path(APP_DIR, "app.R")
  if (normalizePath(source_file, winslash="/", mustWork=FALSE) != normalizePath(target_file, winslash="/", mustWork=FALSE)) {
    file.copy(source_file, target_file, overwrite = TRUE)
    message("Successfully copied to app.R in the root directory.")
  } else {
    message("App file is already named app.R in the correct location. Skipping copy.")
  }
}

# -----------------------------------------------------------------------------
# 3. Configuration
# -----------------------------------------------------------------------------
APP_NAME    <- "Plant Identification AI"
APP_VERSION <- "1.0.0"

R_VER       <- paste(R.version$major, R.version$minor, sep = ".")
message("Bundling R version: ", R_VER)

PACKAGES    <- c("shiny", "bslib", "DT", "DBI", "RSQLite", "magick", "base64enc",
                 "httr", "jsonlite", "torch", "torchvision", "ggplot2", "plotly",
                 "shinycssloaders", "shinytoastr", "digest")

# -----------------------------------------------------------------------------
# 4. Create Inno Setup script
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
# 5. Inject post-install libtorch download
# -----------------------------------------------------------------------------
message("Locating the generated .iss file...")
iss_files <- list.files("installer_output", pattern = "\\.iss$", full.names = TRUE)

if (length(iss_files) == 0) {
  stop("Could not find any .iss file in the installer_output folder! Files present: ", 
       paste(list.files("installer_output"), collapse = ", "))
}

iss_path <- iss_files[1]
message("Found .iss file at: ", iss_path)

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
# 6. Compile
# -----------------------------------------------------------------------------
if (nchar(Sys.which("iscc")) == 0) {
  Sys.setenv(PATH = paste("C:/Program Files (x86)/Inno Setup 6", Sys.getenv("PATH"), sep = ";"))
}
compile_iss(iss_path = iss_path)

message("\n==============================================")
message("Build complete: installer_output/", APP_NAME, "_", APP_VERSION, ".exe")
message("First install needs internet (downloads libtorch).")
message("==============================================")
