# =============================================================================
# build_windows_installer.R – FIXED (copy existing R, no download)
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
# 1.5 MONKEY-PATCH RInno for R 4.x compatibility AND replace get_R
# -----------------------------------------------------------------------------
message("Applying patches to RInno...")

# Fix HTML scraping (as before)
fn_code <- getFromNamespace("code_section", "RInno")
b <- deparse(body(fn_code))
b <- gsub("\\[1-3\\]", "[1-9]", b)
b <- gsub("latest_R_version == R_version", "latest_R_version[1] == R_version", b)
body(fn_code) <- as.call(parse(text = paste(b, collapse = "\n"))[[1]])
assignInNamespace("code_section", fn_code, ns = "RInno")

# Replace get_R to copy current R instead of downloading
fn_getR <- getFromNamespace("get_R", "RInno")
body(fn_getR) <- quote({
  dest <- file.path(app_dir, "R-Portable")
  if (!dir.exists(dest)) {
    message("Copying R from ", R.home(), " to ", dest)
    # Use robocopy on Windows for reliable recursive copy
    if (Sys.info()["sysname"] == "Windows") {
      # robocopy source dest /E /COPY:DAT /R:0 /W:0
      cmd <- sprintf("robocopy %s %s /E /COPY:DAT /R:0 /W:0",
                     shQuote(R.home()), shQuote(dest))
      res <- system(cmd, wait = TRUE, intern = FALSE, ignore.stdout = TRUE, ignore.stderr = TRUE)
      if (res >= 8) {
        # robocopy exit codes: 0-7 are success, 8+ means error
        warning("robocopy returned code ", res, " – copying may have failed.")
      }
    } else {
      file.copy(R.home(), dest, recursive = TRUE, copy.date = TRUE)
    }
    message("R copied successfully.")
  } else {
    message("R-Portable already exists, skipping copy.")
  }
  # Return TRUE to signal success
  return(TRUE)
})
assignInNamespace("get_R", fn_getR, ns = "RInno")

# -----------------------------------------------------------------------------
# 2. Setup Directories & auto-detect app.R
# -----------------------------------------------------------------------------
APP_DIR <- Sys.getenv("GITHUB_WORKSPACE", unset = getwd())
setwd(APP_DIR)
message("Working directory: ", APP_DIR)

# Find the main app file (excluding this script)
all_r_files <- list.files(APP_DIR, pattern = "\\.R$", full.names = TRUE, recursive = TRUE)
candidates <- all_r_files[!grepl("build_windows_installer\\.R$", all_r_files)]

if (length(candidates) == 0) {
  stop("No .R file found in any subdirectory.")
} else {
  source_file <- candidates[1]
  message("Found app file: ", source_file)
  target_file <- file.path(APP_DIR, "app.R")
  if (normalizePath(source_file, winslash="/", mustWork=FALSE) !=
      normalizePath(target_file, winslash="/", mustWork=FALSE)) {
    file.copy(source_file, target_file, overwrite = TRUE)
    message("Copied to app.R in root.")
  } else {
    message("app.R already in root.")
  }
}

# -----------------------------------------------------------------------------
# 3. Configuration
# -----------------------------------------------------------------------------
APP_NAME    <- "Plant Identification AI"
APP_VERSION <- "1.0.0"

# Keep this! create_app needs it to build paths internally, even if we don't download.
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
# 5. Inject post-install libtorch download & clean up ISS
# -----------------------------------------------------------------------------
iss_files <- list.files("installer_output", pattern = "\\.iss$", full.names = TRUE)
if (length(iss_files) == 0) {
  stop("No .iss file generated! Check create_app output above.\n",
       "Contents of installer_output: ", paste(list.files("installer_output"), collapse = ", "))
}
iss_path <- iss_files[1]
message("Found .iss file: ", iss_path)

iss_lines <- readLines(iss_path)

# NEW: Strip out any lines mentioning the CRAN .exe installer so compilation doesn't fail
iss_lines <- iss_lines[!grepl("win\\.exe", iss_lines)]

run_idx <- grep("^\\[Run\\]", iss_lines)
torch_line <- 'Filename: "{app}\\R-Portable\\bin\\Rscript.exe"; Parameters: "-e ""torch::install_torch()"""; StatusMsg: "Downloading neural network engine..."; Flags: runhidden waituntilterminated'

if (length(run_idx) > 0) {
  iss_lines <- append(iss_lines, torch_line, after = run_idx[1])
} else {
  iss_lines <- c(iss_lines, "[Run]", torch_line)
}
writeLines(iss_lines, iss_path)

# -----------------------------------------------------------------------------
# 6. Compile the installer
# -----------------------------------------------------------------------------
# Ensure Inno Setup compiler is in PATH
if (nchar(Sys.which("iscc")) == 0) {
  Sys.setenv(PATH = paste("C:/Program Files (x86)/Inno Setup 6", Sys.getenv("PATH"), sep = ";"))
}
compile_iss(iss_path = iss_path)

message("\n==============================================")
message("Build complete: installer_output/", APP_NAME, "_", APP_VERSION, ".exe")
message("The installer will copy the current R (", R.version.string, ") and")
message("download libtorch on first run (requires internet).")
message("==============================================")
