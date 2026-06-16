# =============================================================================
# build_portable_bundle.R
#
# Builds a portable, no-installer Windows distribution by:
#   1. Copying the runner's own R installation (your robocopy approach —
#      this part already proved itself working in your RInno attempt)
#   2. Installing every required package directly into that copy's library
#   3. Copying the app file in
#   4. Writing a double-click launcher .bat
#   5. Zipping the whole folder
#
# No RInno, no Inno Setup, no orphaned-package internals to patch. End users
# unzip the result and double-click Launch_PlantIDApp.bat — no installer
# wizard, no admin rights, nothing else to install except this one file.
# =============================================================================

if (!requireNamespace("zip", quietly = TRUE)) {
  install.packages("zip", repos = "https://cloud.r-project.org")
}

APP_DIR <- Sys.getenv("GITHUB_WORKSPACE", unset = getwd())
setwd(APP_DIR)
message("Working directory: ", APP_DIR)

DIST_DIR <- file.path(APP_DIR, "dist", "PlantIDApp")
R_DEST   <- file.path(DIST_DIR, "R-Portable")
LIB_DEST <- file.path(R_DEST, "library")

if (dir.exists(file.path(APP_DIR, "dist"))) unlink(file.path(APP_DIR, "dist"), recursive = TRUE)
dir.create(LIB_DEST, recursive = TRUE, showWarnings = FALSE)

# ── 1. Copy the existing R installation ───────────────────────────────────────
message("Copying R from ", R.home(), " to ", R_DEST)
if (.Platform$OS.type == "windows") {
  cmd <- sprintf('robocopy "%s" "%s" /E /COPY:DAT /R:0 /W:0', R.home(), R_DEST)
  res <- system(cmd, ignore.stdout = TRUE, ignore.stderr = TRUE)
  # robocopy's exit codes are bit flags; 0-7 all mean "succeeded with some
  # combination of copies/skips", only >=8 indicates a real failure.
  if (res >= 8) stop("robocopy failed with exit code ", res)
} else {
  file.copy(R.home(), R_DEST, recursive = TRUE)
}
message("R copied successfully.")

# ── 2. Install every required package directly into the portable library ────
PACKAGES <- c(
  "shiny", "bslib", "DT", "DBI", "RSQLite", "magick", "base64enc",
  "httr", "jsonlite", "torch", "torchvision", "ggplot2", "plotly",
  "shinycssloaders", "shinytoastr", "digest"
)

message("Installing ", length(PACKAGES), " packages into the portable library (this is the slow step — ggplot2/plotly/torch pull in a fair number of dependencies)...")
install.packages(PACKAGES, lib = LIB_DEST, repos = "https://cloud.r-project.org")

still_missing <- PACKAGES[!sapply(PACKAGES, function(p) {
  requireNamespace(p, lib.loc = LIB_DEST, quietly = TRUE)
})]
if (length(still_missing) > 0) {
  stop("These packages failed to install into the portable library: ",
       paste(still_missing, collapse = ", "),
       "\nCheck the install.packages() output above this line for the real error.")
}
message("All ", length(PACKAGES), " packages installed and verified.")

# ── 3. Copy the app file in ───────────────────────────────────────────────────
all_r_files <- list.files(APP_DIR, pattern = "\\.R$", full.names = TRUE, recursive = FALSE)
candidates  <- all_r_files[!grepl("build_(windows_installer|portable_bundle)\\.R$", all_r_files)]
if (length(candidates) == 0) stop("No app .R file found in ", APP_DIR)
source_file <- candidates[1]
message("App file detected: ", basename(source_file))
file.copy(source_file, file.path(DIST_DIR, "app.R"), overwrite = TRUE)

# ── 4. Write the launcher and a short README ──────────────────────────────────
launcher <- file.path(DIST_DIR, "Launch_PlantIDApp.bat")
writeLines(c(
  "@echo off",
  "title Plant Identification AI",
  "cd /d \"%~dp0\"",
  "\"%~dp0R-Portable\\bin\\Rscript.exe\" -e \"shiny::runApp('app.R', launch.browser=TRUE, port=3838, host='127.0.0.1')\"",
  "echo.",
  "echo The app has stopped. Press any key to close this window.",
  "pause >nul"
), launcher)

readme <- file.path(DIST_DIR, "README.txt")
writeLines(c(
  "Plant Identification AI",
  "Author: Muralidharan Mani, Ph.D.",
  "Department of Biochemistry, University of Wisconsin-Madison",
  "",
  "HOW TO RUN",
  "----------",
  "Double-click Launch_PlantIDApp.bat",
  "",
  "The first launch will automatically download the neural network engine",
  "(libtorch, roughly 500MB-1GB) -- this needs internet access and only",
  "happens once. You'll see progress messages in the console window.",
  "",
  "No R installation, no admin rights, and nothing else needs to be",
  "installed -- everything required is already in this folder."
), readme)

# ── 5. Zip it up ───────────────────────────────────────────────────────────────
out_dir  <- file.path(APP_DIR, "installer_output")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
zip_path <- file.path(out_dir, "PlantIDApp_Windows_Portable.zip")

old_wd <- getwd()
setwd(file.path(APP_DIR, "dist"))
zip::zip(zip_path, files = "PlantIDApp", recurse = TRUE)
setwd(old_wd)

message("\n==============================================")
message("Build complete: ", zip_path)
message("Unzip on any Windows machine and double-click Launch_PlantIDApp.bat")
message("==============================================")
