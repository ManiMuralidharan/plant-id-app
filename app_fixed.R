# ============================================================================
# Plant Identification Shiny App — FIXED & IMPROVED VERSION
# ============================================================================
# Fixes applied (see inline "# FIXED:" comments for each):
#   1. novelty_top_k(): data.frame() can't self-reference a column being
#      created in the same call -> crashed on every identification attempt.
#   2. unserialise_emb(): erroneous [[1]] truncated every stored embedding
#      down to a single number -> silently broke all species matching.
#   3. shinytoastr::useToastr() was never called -> no notifications worked.
#   4. sys.executable() is not a real R function -> errored outside RStudio.
#   5. DB_PATH reassigned inside server() never reached the helper functions
#      (different scope) -> the override was dead code.
#   6. upsert_species() discarded prior embeddings on every new photo for the
#      same species -> image_count was tracked but never actually used.
#   7. Missing --dark-color CSS variable, missing DT Buttons extension,
#      missing location_name input, missing common_name in match results.
#   8. All DB connections now use on.exit() so a mid-function error can't
#      leak an open SQLite handle.
#   9. Removed unused {leaflet} import and the non-functional "map picker" /
#      "get current location" stub controls to keep the dependency list
#      (and a future compiled build) leaner. See chat for how to re-add a
#      real geolocation/map feature if you want it.
# ============================================================================

# 1. LIBRARIES ----------------------------------------------------------------
library(shiny)
library(bslib)
library(DT)
library(DBI)
library(RSQLite)
library(magick)
library(base64enc)
library(httr)
library(jsonlite)
library(torch)
library(torchvision)
library(ggplot2)
library(plotly)
library(shinycssloaders)
library(shinytoastr)
# NOTE: %||% is base R since 4.4.0 (you're on 4.5.2, so this is fine).
#       digest::digest() is called with an explicit :: below, so it doesn't
#       need library(digest) — just make sure the package is installed.

# Auto-installs libtorch (the ~500MB-1GB neural network engine that {torch}
# downloads separately from the R package itself) the first time the app
# runs, if it isn't already present. This makes the app self-sufficient
# regardless of how it was distributed (portable zip, installer, or just
# running app.R directly) — no separate install step needs to remember to
# trigger this. Needs internet access; only happens once.
if (!torch::torch_is_installed()) {
  message("First-time setup: downloading the neural network engine (libtorch).")
  message("This requires internet access and may take a few minutes — it only happens once.")
  torch::install_torch()
}

# FIXED (#4 + #5): a single robust app-directory resolver used to build
# DB_PATH ONCE at the top level, so every helper function (which all live in
# the global environment) sees the same correct path — whether you're running
# this interactively, via Rscript, or from a compiled/portable launcher.
get_app_dir <- function() {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg))))
  }
  getwd()
}

DB_PATH <- file.path(get_app_dir(), "plant_species.sqlite")

# 2. GLOBAL CONFIGURATION -----------------------------------------------------
MODEL_VERSION <- "resnet50-imagenet-v1"
SIM_THRESHOLD <- 0.45
TOP_K         <- 5

COLORS <- list(
  primary   = "#2E7D32",
  secondary = "#FFA000",
  success   = "#43A047",
  info      = "#1E88E5",
  warning   = "#FB8C00",
  danger    = "#E53935",
  dark      = "#1B5E20",
  light     = "#F1F8E9",
  gradient1 = "#66BB6A",
  gradient2 = "#2E7D32"
)

# 3. DEEP LEARNING FUNCTIONS ---------------------------------------------------
load_model <- function() {
  cat("Loading ResNet-50 (pretrained) ...\n")
  model <- model_resnet50(pretrained = TRUE)
  model$fc <- nn_identity()
  model$eval()
  if (cuda_is_available()) {
    model <- model$cuda()
    cat("Model loaded on GPU\n")
  } else {
    cat("Model loaded on CPU\n")
  }
  cat("Model ready.\n")
  model
}

preprocess_image <- function(img_path) {
  img <- image_read(img_path) |>
    image_resize("224x224") |>
    image_data(channels = "rgb")

  img <- as.numeric(img[[1]]) / 255
  img <- aperm(img, c(3, 1, 2))

  mean <- c(0.485, 0.456, 0.406)
  std  <- c(0.229, 0.224, 0.225)
  for (i in 1:3) {
    img[i, , ] <- (img[i, , ] - mean[i]) / std[i]
  }

  tensor <- torch_tensor(img, dtype = torch_float32())$unsqueeze(1)
  if (cuda_is_available()) tensor <- tensor$cuda()
  tensor
}

extract_embedding <- function(model, img_path) {
  tensor <- preprocess_image(img_path)
  with_no_grad({
    features <- model(tensor)
    # With fc replaced by nn_identity(), ResNet-50's forward() has already
    # done avgpool + flatten before reaching here, so this is always 2D.
    # Kept as a defensive fallback only.
    if (length(dim(features)) == 4) {
      features <- features$mean(dim = c(3, 4))
    }
    emb <- as.numeric(features$squeeze()$cpu())
  })
  emb / sqrt(sum(emb^2))
}

# FIXED (#improvement): a lenient image-quality gate. A strict blur threshold
# rejects perfectly good photos (learned the hard way in an earlier version
# of this project) — resize to a fixed scale first, then use a very low
# variance cutoff that only catches genuinely blank/corrupt images.
check_image_quality <- function(img_path) {
  info <- file.info(img_path)
  if (is.na(info$size) || info$size < 1000) {
    return(list(ok = FALSE, reason = "Image file too small or unreadable."))
  }
  img <- tryCatch(image_read(img_path), error = function(e) NULL)
  if (is.null(img)) return(list(ok = FALSE, reason = "Could not decode image file."))

  dims <- image_info(img)
  if (dims$width[1] < 50 || dims$height[1] < 50) {
    return(list(ok = FALSE, reason = sprintf(
      "Image too small (%dx%d px). Please use a larger photo.",
      dims$width[1], dims$height[1])))
  }

  grey <- image_convert(image_resize(img, "224x224"), colorspace = "gray")
  arr  <- as.numeric(image_data(grey, channels = "gray")[[1]])
  arr  <- matrix(arr, nrow = 224, ncol = 224)
  lap  <- arr[2:223, 2:223] * 4 - arr[1:222, 2:223] - arr[3:224, 2:223] -
          arr[2:223, 1:222] - arr[2:223, 3:224]

  if (var(as.vector(lap)) < 1e-6) {
    return(list(ok = FALSE, reason = "Image appears blank or completely uniform."))
  }
  list(ok = TRUE, reason = "")
}

# 4. DATABASE FUNCTIONS (SQLite) ----------------------------------------------
init_db <- function() {
  con <- dbConnect(SQLite(), DB_PATH)
  on.exit(dbDisconnect(con), add = TRUE)   # FIXED (#8): always closes, even on error

  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS species (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      scientific_name TEXT UNIQUE NOT NULL,
      common_name     TEXT,
      family          TEXT,
      habitat         TEXT,
      region          TEXT,
      conservation    TEXT,
      model_version   TEXT,
      embedding       BLOB,
      created_at      TEXT,
      image_count     INTEGER DEFAULT 1,
      last_updated    TEXT
    )
  ")

  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS review_queue (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      img_path         TEXT,
      embedding        BLOB,
      nearest_species  TEXT,
      nearest_dist     REAL,
      gps_lat          REAL,
      gps_lon          REAL,
      collector_note   TEXT,
      status           TEXT DEFAULT 'pending',
      model_version    TEXT,
      submitted_at     TEXT,
      review_notes     TEXT,
      reviewed_by      TEXT,
      reviewed_at      TEXT
    )
  ")

  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS identification_history (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      species_name     TEXT,
      confidence       REAL,
      gps_lat          REAL,
      gps_lon          REAL,
      location_name    TEXT,
      identified_at    TEXT,
      image_hash       TEXT
    )
  ")
}

serialise_emb   <- function(emb) serialize(emb, NULL)
# FIXED (#2): removed the erroneous [[1]] — serialise_emb() never wrapped the
# vector in a list, so unserialize() already returns the full embedding as-is.
unserialise_emb <- function(blob) unserialize(blob)

upsert_species <- function(name, common, family, habitat, region, conservation, embedding) {
  con <- dbConnect(SQLite(), DB_PATH)
  on.exit(dbDisconnect(con), add = TRUE)
  created_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  existing <- dbGetQuery(con,
    "SELECT id, image_count, embedding FROM species WHERE scientific_name = ?",
    params = list(name))

  if (nrow(existing) == 0) {
    dbExecute(con, "
      INSERT INTO species
      (scientific_name, common_name, family, habitat, region, conservation,
       model_version, embedding, created_at, image_count, last_updated)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)",
      params = list(name, common, family, habitat, region, conservation,
                    MODEL_VERSION, list(serialise_emb(embedding)), created_at, created_at))
  } else {
    # FIXED (#6): running average of all reference photos for this species,
    # re-normalised, instead of discarding every previous photo's embedding.
    old_emb   <- unserialise_emb(existing$embedding[[1]])
    old_count <- existing$image_count[1]
    new_count <- old_count + 1
    combined  <- (old_emb * old_count + embedding) / new_count
    combined  <- combined / sqrt(sum(combined^2))

    dbExecute(con, "
      UPDATE species
      SET common_name = ?, family = ?, habitat = ?, region = ?, conservation = ?,
          model_version = ?, embedding = ?, last_updated = ?, image_count = ?
      WHERE scientific_name = ?",
      params = list(common, family, habitat, region, conservation,
                    MODEL_VERSION, list(serialise_emb(combined)), created_at, new_count, name))
  }
}

get_all_embeddings <- function() {
  con <- dbConnect(SQLite(), DB_PATH)
  on.exit(dbDisconnect(con), add = TRUE)
  # FIXED (#7): now also selects common_name so match results can show it.
  df <- dbGetQuery(con, "SELECT id, scientific_name, common_name, embedding FROM species")
  if (nrow(df) == 0) return(data.frame())
  df$embedding <- lapply(df$embedding, unserialise_emb)
  df
}

list_species <- function() {
  con <- dbConnect(SQLite(), DB_PATH)
  on.exit(dbDisconnect(con), add = TRUE)
  dbGetQuery(con, "SELECT id, scientific_name, common_name, family, region, conservation, image_count, model_version, created_at, last_updated FROM species ORDER BY scientific_name")
}

enqueue_unknown <- function(img_path, embedding, nearest_species, nearest_dist, lat, lon, note) {
  con <- dbConnect(SQLite(), DB_PATH)
  on.exit(dbDisconnect(con), add = TRUE)
  submitted_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  dbExecute(con, "
    INSERT INTO review_queue
    (img_path, embedding, nearest_species, nearest_dist, gps_lat, gps_lon,
     collector_note, status, model_version, submitted_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    params = list(img_path, list(serialise_emb(embedding)), nearest_species, nearest_dist,
                  lat, lon, note, "pending", MODEL_VERSION, submitted_at))
}

list_queue <- function() {
  con <- dbConnect(SQLite(), DB_PATH)
  on.exit(dbDisconnect(con), add = TRUE)
  dbGetQuery(con, "SELECT id, nearest_species, nearest_dist, gps_lat, gps_lon, collector_note, submitted_at, status FROM review_queue WHERE status = 'pending' ORDER BY submitted_at DESC")
}

save_identification <- function(species, confidence, lat, lon, location, image_hash) {
  con <- dbConnect(SQLite(), DB_PATH)
  on.exit(dbDisconnect(con), add = TRUE)
  identified_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  dbExecute(con, "
    INSERT INTO identification_history
    (species_name, confidence, gps_lat, gps_lon, location_name, identified_at, image_hash)
    VALUES (?, ?, ?, ?, ?, ?, ?)",
    params = list(species, confidence, lat, lon, location, identified_at, image_hash))
}

get_identification_stats <- function() {
  con <- dbConnect(SQLite(), DB_PATH)
  on.exit(dbDisconnect(con), add = TRUE)

  total <- dbGetQuery(con, "SELECT COUNT(*) as count FROM identification_history")$count
  top_species <- dbGetQuery(con, "
    SELECT species_name, COUNT(*) as count, AVG(confidence) as avg_conf
    FROM identification_history
    GROUP BY species_name
    ORDER BY count DESC
    LIMIT 10")
  recent <- dbGetQuery(con, "
    SELECT species_name, confidence, location_name, identified_at
    FROM identification_history
    ORDER BY identified_at DESC
    LIMIT 20")

  list(total = total, top_species = top_species, recent = recent)
}

# 5. SIMILARITY & NOVELTY -------------------------------------------------------
cosine_distance <- function(emb1, emb2) 1 - sum(emb1 * emb2)

# FIXED (#1): "confidence" is now computed as a plain vector BEFORE the
# data.frame() call, then reused — data.frame() cannot reference a column
# being created in the same call (that's a dplyr::mutate() behaviour, not
# base R). Also widened cut() bounds to -Inf/Inf so confidence values of
# exactly 0 or 100 don't fall outside the breaks and become NA.
novelty_top_k <- function(query_emb, db_df, k = TOP_K) {
  if (nrow(db_df) == 0) {
    return(data.frame(
      rank = 1, scientific_name = "Unknown", common_name = NA_character_,
      distance = Inf, confidence = 0,
      confidence_level = factor("Low", levels = c("Low","Medium","High","Very High")),
      is_novel = TRUE, stringsAsFactors = FALSE
    ))
  }

  dists <- sapply(db_df$embedding, function(ref_emb) cosine_distance(query_emb, ref_emb))
  ord   <- order(dists)
  k     <- min(k, length(dists))
  idx   <- ord[1:k]

  sel_dist <- dists[idx]
  conf     <- pmax(0, (1 - sel_dist) * 100)
  conf_lvl <- cut(conf, breaks = c(-Inf, 50, 75, 90, Inf),
                  labels = c("Low", "Medium", "High", "Very High"))

  common <- if ("common_name" %in% names(db_df)) db_df$common_name[idx] else NA_character_

  data.frame(
    rank              = seq_len(k),
    scientific_name   = db_df$scientific_name[idx],
    common_name       = common,
    distance          = sel_dist,
    confidence        = conf,
    confidence_level  = conf_lvl,
    is_novel          = sel_dist > SIM_THRESHOLD,
    stringsAsFactors  = FALSE
  )
}

# 6. WEB SEARCH FUNCTIONS -------------------------------------------------------
call_google_vision <- function(img_path, api_key) {
  if (is.null(api_key) || api_key == "") return(NULL)

  img_base64 <- base64encode(img_path)
  body <- list(
    requests = list(
      list(
        image = list(content = img_base64),
        features = list(list(type = "WEB_DETECTION", maxResults = 10))
      )
    )
  )

  resp <- POST(url = sprintf("https://vision.googleapis.com/v1/images:annotate?key=%s", api_key),
               add_headers("Content-Type" = "application/json"),
               body = toJSON(body, auto_unbox = TRUE))

  if (status_code(resp) != 200) return(NULL)

  data <- content(resp, "parsed")
  web <- data$responses[[1]]$webDetection
  if (is.null(web)) return(list(ok = TRUE, best_guess = NULL, entities = data.frame(), pages = data.frame()))

  best_guess <- tryCatch(web$bestGuessLabels[[1]]$label, error = function(e) NULL)

  entities <- if (!is.null(web$webEntities)) {
    data.frame(
      description = sapply(web$webEntities, function(x) x$description %||% NA),
      score = sapply(web$webEntities, function(x) x$score %||% NA)
    )
  } else data.frame()

  pages <- if (!is.null(web$pagesWithMatchingImages)) {
    data.frame(
      title = sapply(web$pagesWithMatchingImages, function(x) x$pageTitle %||% NA),
      url = sapply(web$pagesWithMatchingImages, function(x) x$url %||% NA)
    )
  } else data.frame()

  list(ok = TRUE, best_guess = best_guess, entities = entities, pages = pages)
}

call_bing_visual <- function(img_path, api_key) {
  if (is.null(api_key) || api_key == "") return(NULL)

  boundary <- "BingBoundary1234"
  img_raw <- readBin(img_path, "raw", file.info(img_path)$size)

  body <- c(
    charToRaw(paste0("--", boundary, "\r\n",
                     "Content-Disposition: form-data; name=\"image\"; filename=\"plant.jpg\"\r\n",
                     "Content-Type: image/jpeg\r\n\r\n")),
    img_raw,
    charToRaw(paste0("\r\n--", boundary, "--\r\n"))
  )

  resp <- POST("https://api.bing.microsoft.com/v7.0/images/visualsearch",
               add_headers(`Ocp-Apim-Subscription-Key` = api_key,
                           `Content-Type` = paste0("multipart/form-data; boundary=", boundary)),
               body = body)

  if (status_code(resp) != 200) return(NULL)

  data <- content(resp, "parsed")
  best_name <- NULL
  pages <- data.frame(title = character(), url = character())

  for (tag in data$tags) {
    for (action in tag$actions) {
      if (action$actionType == "Entity" && is.null(best_name))
        best_name <- action$data$name
      if (action$actionType == "PagesIncluding") {
        pages <- do.call(rbind, lapply(action$data$value, function(pg) {
          data.frame(title = pg$name, url = pg$hostPageUrl, stringsAsFactors = FALSE)
        }))
      }
    }
  }

  list(ok = TRUE, best_name = best_name, pages = pages)
}

fetch_wikipedia <- function(plant_name) {
  if (is.null(plant_name) || plant_name == "") return(NULL)

  encoded <- URLencode(plant_name, reserved = TRUE)
  url <- paste0("https://en.wikipedia.org/api/rest_v1/page/summary/", encoded)
  resp <- GET(url)

  if (status_code(resp) != 200) return(NULL)

  data <- content(resp, "parsed")
  list(ok = TRUE, title = data$title, summary = data$extract,
       url = data$content_urls$desktop$page, thumbnail = data$thumbnail$source)
}

# 7. SHINY UI -------------------------------------------------------------------
custom_css <- "
:root {
  --primary-color: #2E7D32;
  --secondary-color: #FFA000;
  --success-color: #43A047;
  --info-color: #1E88E5;
  --warning-color: #FB8C00;
  --danger-color: #E53935;
  --dark-color: #1B5E20;
}

.shiny-input-container { margin-bottom: 15px; }

.well-panel-custom {
  background: linear-gradient(135deg, #f5f5f5 0%, #ffffff 100%);
  border-left: 4px solid var(--primary-color);
  border-radius: 8px;
  padding: 15px;
  margin-bottom: 15px;
  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
  transition: transform 0.2s;
}

.well-panel-custom:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 8px rgba(0,0,0,0.15);
}

.confidence-high { color: var(--success-color); font-weight: bold; }
.confidence-medium { color: var(--warning-color); font-weight: bold; }
.confidence-low { color: var(--danger-color); font-weight: bold; }

.stats-card {
  background: linear-gradient(135deg, var(--primary-color), var(--dark-color));
  color: white;
  border-radius: 10px;
  padding: 20px;
  text-align: center;
  margin: 10px 0;
}

.stats-number { font-size: 32px; font-weight: bold; }
.stats-label { font-size: 14px; opacity: 0.9; }

.startup-splash {
  position: fixed;
  top: 0; left: 0; width: 100%; height: 100%;
  background: linear-gradient(135deg, var(--primary-color), var(--dark-color));
  z-index: 9999;
  display: flex;
  align-items: center;
  justify-content: center;
}

.startup-splash-inner {
  background: white;
  border-radius: 16px;
  padding: 40px 50px;
  text-align: center;
  box-shadow: 0 10px 40px rgba(0,0,0,0.3);
  max-width: 480px;
}

.startup-splash-inner h2 { color: var(--primary-color); margin-bottom: 4px; }
.splash-sub { color: #888; margin-top: 0; font-size: 0.95em; }
.splash-loading-text { color: #666; font-size: 0.9em; margin-top: 12px; }

.splash-spinner {
  margin: 16px auto 4px;
  width: 36px; height: 36px;
  border: 4px solid #e0e0e0;
  border-top: 4px solid var(--primary-color);
  border-radius: 50%;
  animation: splash-spin 1s linear infinite;
}

@keyframes splash-spin { to { transform: rotate(360deg); } }

.app-footer {
  text-align: center;
  color: #999;
  font-size: 0.8em;
  padding: 10px 0;
}
"

ui <- page_navbar(
  title = tags$div(
    tags$img(src = "https://cdn-icons-png.flaticon.com/512/1995/1995572.png",
             height = "30px", style = "margin-right: 10px;"),
    "Plant Identification AI - Enhanced Edition"
  ),
  theme = bs_theme(
    bootswatch = "flatly",
    primary = COLORS$primary,
    secondary = COLORS$secondary,
    success = COLORS$success,
    info = COLORS$info,
    warning = COLORS$warning,
    danger = COLORS$danger,
    bg = "#ffffff",
    fg = "#2c3e50",
    base_font = font_google("Roboto"),
    heading_font = font_google("Montserrat")
  ),
  # FIXED (#10): page_navbar() expects every unnamed argument to be a
  # nav_panel()/nav_menu() — tags$head() and useToastr() are neither, which
  # is exactly what the "Navigation containers expect a collection of
  # nav_panel()..." warning is telling you. bslib provides `header=` for
  # exactly this case: content that should render once, outside the nav
  # panels themselves.
  # FIXED (#3): useToastr() registers the JS message handler that
  # toastr_success()/error()/info()/warning() actually depend on — without
  # it, every toast notification call silently does nothing. It also
  # supplies its own toastr.js/css, so the old manual CDN <script>/<link>
  # tags were removed to avoid loading two copies.
  header = tagList(
    tags$head(tags$style(custom_css)),
    useToastr(),

    # Startup splash — this <div> is part of the static HTML the browser
    # paints immediately on page load (it doesn't wait on any server round
    # trip), so your name/affiliation are visible from the very first
    # instant the app opens. conditionalPanel's JS-side condition starts
    # as TRUE by default (since output.app_ready is undefined until the
    # server responds), then flips to hidden once the model finishes
    # loading via output$app_ready in server().
    conditionalPanel(
      condition = "!output.app_ready",
      div(class = "startup-splash",
        div(class = "startup-splash-inner",
          h2("🌿 Plant Identification AI"),
          p(class = "splash-sub", "Enhanced Edition"),
          hr(),
          p(strong("Author: "), "Muralidharan Mani, Ph.D."),
          p(strong("Affiliation: "), "Department of Biochemistry, University of Wisconsin-Madison"),
          div(class = "splash-spinner"),
          p(class = "splash-loading-text", "Loading AI model, please wait...")
        )
      )
    ),

    # Persistent attribution footer — stays visible on every tab after the
    # splash disappears, so the affiliation isn't just a one-time flash.
    div(class = "app-footer",
      sprintf("© %s Muralidharan Mani, Ph.D. — Department of Biochemistry, University of Wisconsin-Madison",
              format(Sys.Date(), "%Y"))
    )
  ),

  nav_panel(
    "🔍 Identify",
    layout_sidebar(
      sidebar = sidebar(
        width = 350,
        div(class = "well-panel-custom",
          fileInput("image",
                    tags$b("📸 Upload Plant Photo"),
                    accept = c("image/jpeg", "image/png", "image/jpg"),
                    buttonLabel = "Browse...",
                    placeholder = "No file selected"),
          p(class = "text-muted", "Supports JPEG and PNG formats")
        ),

        div(class = "well-panel-custom",
          h5("📍 Location Information"),
          numericInput("gps_lat", "Latitude", value = 0, step = 0.0001),
          numericInput("gps_lon", "Longitude", value = 0, step = 0.0001),
          # FIXED (#7): this field is now defined — previously the "Save
          # This Identification" handler referenced input$location_name even
          # though no such input existed anywhere in the UI.
          textInput("location_name", "Location Name", placeholder = "e.g. Western Ghats Trail")
        ),

        div(class = "well-panel-custom",
          h5("📝 Field Notes"),
          textAreaInput("field_note", "Observations", rows = 3,
                        placeholder = "Enter any additional observations about the plant...")
        ),

        actionButton("analyze", "🌿 Identify Plant",
                     icon = icon("leaf"),
                     class = "btn-success btn-lg",
                     style = "width: 100%; margin-bottom: 10px;"),

        conditionalPanel(
          condition = "output.identification_ready",
          actionButton("submit_unknown", "📤 Submit for Review",
                       icon = icon("question-circle"),
                       class = "btn-warning btn-lg",
                       style = "width: 100%; margin-bottom: 10px;"),

          actionButton("save_identification", "💾 Save This Identification",
                       icon = icon("floppy-disk"),
                       class = "btn-info btn-lg",
                       style = "width: 100%;")
        ),

        hr(),

        div(class = "well-panel-custom",
          h5("🔧 Quality Check"),
          verbatimTextOutput("quality_status")
        )
      ),

      mainPanel(
        div(class = "well-panel-custom",
          h4("📷 Uploaded Image"),
          imageOutput("uploaded_img", height = "350px") %>% withSpinner(color = COLORS$primary)
        ),

        conditionalPanel(
          condition = "output.identification_ready",

          div(class = "well-panel-custom",
            h4("🏆 Top Matches"),
            uiOutput("match_panels")
          ),

          div(class = "well-panel-custom",
            h4("📊 Confidence Analysis"),
            plotlyOutput("confidence_gauge", height = "200px")
          ),

          div(class = "well-panel-custom",
            h4("🎯 Novelty Decision"),
            verbatimTextOutput("novelty_msg")
          ),

          div(class = "well-panel-custom",
            h4("ℹ️ Similar Species Information"),
            DTOutput("similar_species_info")
          )
        )
      )
    )
  ),

  nav_panel(
    "🌐 Web Search",
    layout_sidebar(
      sidebar = sidebar(
        width = 350,
        div(class = "well-panel-custom",
          h5("🔑 API Configuration"),
          textInput("google_key", "Google Vision API Key",
                    placeholder = "AIza...",
                    value = Sys.getenv("GOOGLE_API_KEY", "")),
          textInput("bing_key", "Bing Visual Search API Key",
                    placeholder = "Azure API key",
                    value = Sys.getenv("BING_API_KEY", "")),
          actionButton("web_search", "🔍 Search Web",
                       icon = icon("search"),
                       class = "btn-primary",
                       style = "width: 100%;")
        ),

        div(class = "well-panel-custom",
          h5("📋 Combined Results"),
          verbatimTextOutput("summary_local"),
          verbatimTextOutput("summary_google"),
          verbatimTextOutput("summary_bing")
        )
      ),

      mainPanel(
        tabsetPanel(
          tabPanel("Wikipedia",
                   uiOutput("wiki_summary") %>% withSpinner()),
          tabPanel("Google Results",
                   h5("Web Entities"),
                   DTOutput("google_entities"),
                   h5("Matching Pages"),
                   DTOutput("google_pages")),
          tabPanel("Bing Results",
                   h5("Matching Pages"),
                   DTOutput("bing_pages"))
        )
      )
    )
  ),

  nav_panel(
    "📚 Database",
    layout_sidebar(
      sidebar = sidebar(
        width = 350,
        div(class = "well-panel-custom",
          h5("➕ Add New Species"),
          textInput("new_sci", "Scientific Name *", placeholder = "Ocimum tenuiflorum"),
          textInput("new_common", "Common Name", placeholder = "Holy Basil"),
          textInput("new_family", "Family", placeholder = "Lamiaceae"),
          textInput("new_habitat", "Habitat", placeholder = "Tropical dry forests"),
          textInput("new_region", "Region", placeholder = "Southeast Asia"),
          selectInput("new_conserv", "Conservation Status",
                      choices = c("Least Concern", "Near Threatened", "Vulnerable",
                                "Endangered", "Critically Endangered", "Data Deficient"),
                      selected = "Least Concern"),
          fileInput("new_image", "Reference Photo *", accept = c("image/jpeg", "image/png")),
          actionButton("save_species", "💾 Save Species",
                       icon = icon("save"),
                       class = "btn-success",
                       style = "width: 100%;"),
          br(), br(),
          verbatimTextOutput("db_status")
        ),

        div(class = "well-panel-custom",
          h5("📊 Database Statistics"),
          uiOutput("db_stats")
        )
      ),

      mainPanel(
        div(class = "well-panel-custom",
          h4("Species Catalog"),
          DTOutput("species_table") %>% withSpinner()
        )
      )
    )
  ),

  nav_panel(
    "📋 Review Queue",
    div(class = "well-panel-custom",
      h4("Pending Reviews"),
      DTOutput("queue_table") %>% withSpinner(),
      hr(),
      actionButton("refresh_queue", "🔄 Refresh", icon = icon("refresh"), class = "btn-info"),
      actionButton("export_queue", "📥 Export to CSV", icon = icon("download"), class = "btn-success")
    )
  ),

  nav_panel(
    "📈 Analytics",
    fluidRow(
      column(3, div(class = "stats-card",
        div(class = "stats-number", textOutput("total_ids")),
        div(class = "stats-label", "Total Identifications"))),
      column(3, div(class = "stats-card",
        div(class = "stats-number", textOutput("total_species")),
        div(class = "stats-label", "Species in Database"))),
      column(3, div(class = "stats-card",
        div(class = "stats-number", textOutput("pending_reviews")),
        div(class = "stats-label", "Pending Reviews"))),
      column(3, div(class = "stats-card",
        div(class = "stats-number", textOutput("avg_confidence")),
        div(class = "stats-label", "Average Confidence")))
    ),

    fluidRow(
      column(6, div(class = "well-panel-custom",
        h4("Top 10 Most Common Identifications"),
        plotlyOutput("top_species_plot", height = "400px"))),
      column(6, div(class = "well-panel-custom",
        h4("Recent Activity"),
        DTOutput("recent_identifications", height = "400px")))
    ),

    fluidRow(
      column(12, div(class = "well-panel-custom",
        h4("Confidence Distribution"),
        plotlyOutput("confidence_distribution", height = "400px")))
    )
  ),

  nav_menu(
    title = "❓ Help",
    nav_item(tags$a("📘 Documentation", href = "#", onclick = "window.open('https://github.com/your-repo');")),
    nav_item(tags$a("🔑 API Key Guide", href = "https://console.cloud.google.com/apis/", target = "_blank")),
    nav_item(tags$a("🌿 Plant Database", href = "https://www.gbif.org/", target = "_blank")),
    nav_item(tags$a("📧 Support", href = "mailto:support@plantai.com"))
  )
)

# 8. SHINY SERVER -----------------------------------------------------------------
server <- function(input, output, session) {

  rv <- reactiveValues(
    model = NULL,
    model_load_failed = FALSE,
    current_img = NULL,
    current_emb = NULL,
    last_matches = NULL,
    identification_ready = FALSE,
    web_results = list(google = NULL, bing = NULL, wiki = NULL),
    current_image_hash = NULL
  )

  observe({
    init_db()
    tryCatch({
      rv$model <- load_model()
      toastr_success("Model loaded successfully!", position = "top-right")
    }, error = function(e) {
      rv$model_load_failed <- TRUE
      toastr_error(paste("Model loading failed:", e$message), position = "top-right")
    })
    update_species_table()
    update_queue_table()
    update_stats()
  })

  output$identification_ready <- reactive({ rv$identification_ready })
  outputOptions(output, "identification_ready", suspendWhenHidden = FALSE)

  # Drives the startup splash in the UI's header= — it's TRUE the instant the
  # model finishes loading (or fails), which hides the splash automatically.
  # Stays FALSE while load_model() is running, so the splash is what the
  # user sees during that 10-30 second wait instead of a blank-looking app.
  output$app_ready <- reactive({ !is.null(rv$model) || isTRUE(rv$model_load_failed) })
  outputOptions(output, "app_ready", suspendWhenHidden = FALSE)

  update_species_table <- function() {
    output$species_table <- renderDT({
      df <- list_species()
      datatable(df,
                extensions = "Buttons",  # FIXED (#7): required for the export buttons below to render
                options = list(pageLength = 15,
                               scrollX = TRUE,
                               dom = 'Bfrtip',
                               buttons = c('copy', 'csv', 'excel')),
                rownames = FALSE,
                class = 'cell-border stripe hover',
                filter = 'top') %>%
        formatStyle('conservation',
                    backgroundColor = styleEqual(
                      c("Critically Endangered", "Endangered", "Vulnerable",
                        "Near Threatened", "Least Concern", "Data Deficient"),
                      c("#ff9999", "#ffcccc", "#ffffcc", "#fff2cc", "#ccffcc", "#e0e0e0")
                    ))
    })
  }

  update_queue_table <- function() {
    output$queue_table <- renderDT({
      datatable(list_queue(),
                options = list(pageLength = 10, scrollX = TRUE),
                rownames = FALSE,
                class = 'cell-border stripe hover')
    })
  }

  update_stats <- function() {
    stats <- get_identification_stats()

    output$total_ids <- renderText({ stats$total })
    output$total_species <- renderText({ nrow(list_species()) })
    output$pending_reviews <- renderText({ nrow(list_queue()) })

    if (stats$total > 0) {
      avg_conf <- mean(stats$recent$confidence, na.rm = TRUE)
      output$avg_confidence <- renderText({ paste0(round(avg_conf, 1), "%") })
    } else {
      output$avg_confidence <- renderText({ "N/A" })
    }

    output$top_species_plot <- renderPlotly({
      req(stats$top_species)
      plot_ly(stats$top_species,
              x = ~reorder(species_name, count),
              y = ~count,
              type = 'bar',
              marker = list(color = ~count, colorscale = 'Greens', showscale = FALSE),
              text = ~paste("Avg Confidence:", round(avg_conf, 1), "%"),
              hoverinfo = 'text') %>%
        layout(title = "Most Frequently Identified Species",
               xaxis = list(title = ""),
               yaxis = list(title = "Number of Identifications"),
               showlegend = FALSE) %>%
        config(displayModeBar = FALSE)
    })

    output$recent_identifications <- renderDT({
      req(stats$recent)
      datatable(stats$recent, options = list(pageLength = 10), rownames = FALSE)
    })

    output$confidence_distribution <- renderPlotly({
      req(stats$recent)
      plot_ly(stats$recent,
              x = ~confidence,
              type = 'histogram',
              nbinsx = 20,
              marker = list(color = COLORS$primary)) %>%
        layout(title = "Distribution of Identification Confidence",
               xaxis = list(title = "Confidence (%)"),
               yaxis = list(title = "Frequency")) %>%
        config(displayModeBar = FALSE)
    })
  }

  output$db_stats <- renderUI({
    species_count <- nrow(list_species())
    queue_count <- nrow(list_queue())
    tagList(
      p(strong("Total Species:"), species_count),
      p(strong("Pending Reviews:"), queue_count),
      p(strong("Last Updated:"), format(Sys.time(), "%Y-%m-%d %H:%M"))
    )
  })

  observeEvent(input$image, {
    req(input$image)
    rv$current_img <- input$image$datapath
    rv$identification_ready <- FALSE

    output$uploaded_img <- renderImage({
      list(src = rv$current_img,
           contentType = input$image$type,
           height = 350,
           style = "object-fit: contain;")
    }, deleteFile = FALSE)

    rv$current_emb <- NULL
    rv$last_matches <- NULL
    output$quality_status <- renderPrint(cat("✅ Image loaded. Click 'Identify' to analyze."))
  })

  observeEvent(input$analyze, {
    req(rv$current_img)

    if (is.null(rv$model)) {
      toastr_error("Model is not loaded — cannot identify yet.", position = "top-right")
      output$quality_status <- renderPrint(cat("❌ Model not ready. Check the console for load errors."))
      return()
    }

    toastr_info("Extracting deep features...", position = "top-right")

    # FIXED (#improvement): replaced the size-only check with a proper quality gate
    qc <- check_image_quality(rv$current_img)
    if (!qc$ok) {
      output$quality_status <- renderPrint(cat("❌", qc$reason))
      toastr_error(qc$reason, position = "top-right")
      return()
    }

    emb <- tryCatch(extract_embedding(rv$model, rv$current_img), error = function(e) {
      toastr_error(paste("Feature extraction failed:", e$message), position = "top-right")
      NULL
    })

    if (is.null(emb)) {
      output$quality_status <- renderPrint(cat("❌ Feature extraction failed."))
      return()
    }

    rv$current_emb <- emb
    rv$current_image_hash <- digest::digest(emb)
    output$quality_status <- renderPrint(cat("✅ OK – embedding extracted (2048-dim)"))

    db_df <- get_all_embeddings()
    matches <- novelty_top_k(emb, db_df, TOP_K)
    rv$last_matches <- matches
    rv$identification_ready <- TRUE

    if (matches$confidence[1] > 80) {
      save_identification(matches$scientific_name[1],
                         matches$confidence[1],
                         input$gps_lat,
                         input$gps_lon,
                         if (nchar(input$location_name) > 0) input$location_name else "Unknown Location",
                         rv$current_image_hash)
      update_stats()
    }

    output$match_panels <- renderUI({
      lapply(1:nrow(matches), function(i) {
        m <- matches[i, ]
        confidence_class <- if (m$confidence >= 80) "confidence-high"
                            else if (m$confidence >= 50) "confidence-medium"
                            else "confidence-low"

        medal_icon <- if (i == 1) "🥇" else if (i == 2) "🥈" else if (i == 3) "🥉" else "📋"

        div(class = "well-panel-custom",
          h4(paste(medal_icon, "#", i, m$scientific_name)),
          div(class = confidence_class,
              p(strong("Confidence:"), paste0(round(m$confidence, 1), "%"))),
          p(strong("Distance:"), round(m$distance, 4)),
          p(strong("Status:"), ifelse(m$is_novel, "⚠️ Potential Novel Species", "✅ Known Species")),
          p(strong("Confidence Level:"), as.character(m$confidence_level)),
          if (!is.na(m$common_name) && nchar(m$common_name) > 0)
            p(strong("Common Name:"), m$common_name)
        )
      })
    })

    output$confidence_gauge <- renderPlotly({
      top_conf <- matches$confidence[1]
      plot_ly(
        type = "indicator",
        mode = "gauge+number+delta",
        value = top_conf,
        title = list(text = "Top Match Confidence"),
        delta = list(reference = 70),
        gauge = list(
          axis = list(range = list(0, 100), tickwidth = 1),
          bar = list(color = if (top_conf >= 80) COLORS$success
                     else if (top_conf >= 50) COLORS$warning
                     else COLORS$danger),
          steps = list(
            list(range = c(0, 50), color = "lightgray"),
            list(range = c(50, 80), color = "gray"),
            list(range = c(80, 100), color = "darkgray")
          ),
          threshold = list(line = list(color = "red", width = 4), thickness = 0.75, value = 70)
        )
      ) %>%
        layout(height = 200) %>%
        config(displayModeBar = FALSE)
    })

    output$similar_species_info <- renderDT({
      df <- matches[, c("scientific_name", "confidence", "confidence_level", "is_novel")]
      datatable(df, options = list(dom = 't', pageLength = 5), rownames = FALSE) %>%
        formatStyle('confidence',
                    background = styleColorBar(c(0,100), COLORS$primary),
                    backgroundSize = '100% 90%',
                    backgroundRepeat = 'no-repeat',
                    backgroundPosition = 'center')
    })

    if (matches$is_novel[1]) {
      output$novelty_msg <- renderPrint(cat("⚠️ UNKNOWN / POTENTIALLY NOVEL SPECIES – Please submit to review queue for expert validation."))
      toastr_warning("Potential novel species detected!", position = "top-right")
    } else {
      output$novelty_msg <- renderPrint(cat(sprintf("✓ Identified as: %s (%.1f%% confidence)\nThis species is already in our database.",
                                                    matches$scientific_name[1],
                                                    matches$confidence[1])))
      toastr_success(sprintf("Identified: %s", matches$scientific_name[1]), position = "top-right")
    }
  })

  observeEvent(input$save_identification, {
    req(rv$last_matches)
    if (!is.null(rv$last_matches) && nrow(rv$last_matches) > 0) {
      save_identification(rv$last_matches$scientific_name[1],
                         rv$last_matches$confidence[1],
                         input$gps_lat,
                         input$gps_lon,
                         if (nchar(input$location_name) > 0) input$location_name else "Unknown",
                         rv$current_image_hash)
      toastr_success("Identification saved to history!", position = "top-right")
      update_stats()
    }
  })

  observeEvent(input$submit_unknown, {
    req(rv$current_emb, rv$last_matches)

    nearest <- if (!is.null(rv$last_matches)) rv$last_matches$scientific_name[1] else ""
    dist <- if (!is.null(rv$last_matches)) rv$last_matches$distance[1] else Inf
    note <- paste0("Field observations: ", input$field_note)

    enqueue_unknown(rv$current_img, rv$current_emb, nearest, dist,
                    input$gps_lat, input$gps_lon, note)
    update_queue_table()
    update_stats()
    toastr_success("Submitted to review queue. Thank you for contributing!", position = "top-right")
  })

  observeEvent(input$refresh_queue, {
    update_queue_table()
    toastr_info("Queue refreshed", position = "top-right")
  })

  observeEvent(input$export_queue, {
    queue_data <- list_queue()
    if (nrow(queue_data) > 0) {
      write.csv(queue_data, "queue_export.csv", row.names = FALSE)
      toastr_success("Exported to queue_export.csv", position = "top-right")
    } else {
      toastr_info("No data to export", position = "top-right")
    }
  })

  observeEvent(input$web_search, {
    req(rv$current_img)
    toastr_info("Searching web for additional information...", position = "top-right")

    if (!is.null(input$google_key) && input$google_key != "") {
      rv$web_results$google <- call_google_vision(rv$current_img, input$google_key)
    }
    if (!is.null(input$bing_key) && input$bing_key != "") {
      rv$web_results$bing <- call_bing_visual(rv$current_img, input$bing_key)
    }

    best_name <- NULL
    if (!is.null(rv$web_results$google$best_guess)) best_name <- rv$web_results$google$best_guess
    if (is.null(best_name) && !is.null(rv$web_results$bing$best_name)) best_name <- rv$web_results$bing$best_name

    if (!is.null(best_name)) {
      rv$web_results$wiki <- fetch_wikipedia(best_name)
    }

    output$wiki_summary <- renderUI({
      if (!is.null(rv$web_results$wiki) && rv$web_results$wiki$ok) {
        tagList(
          div(class = "well-panel-custom",
            if (!is.null(rv$web_results$wiki$thumbnail))
              img(src = rv$web_results$wiki$thumbnail, height = "150px", style = "float: right; margin: 10px;"),
            h5(rv$web_results$wiki$title),
            p(rv$web_results$wiki$summary),
            actionLink("wiki_link", "📖 Read full article on Wikipedia", icon = icon("external-link-alt"))
          )
        )
      } else {
        div(class = "well-panel-custom", p("No Wikipedia article found for the best match."))
      }
    })

    output$google_entities <- renderDT({
      if (!is.null(rv$web_results$google$entities) && nrow(rv$web_results$google$entities) > 0)
        datatable(rv$web_results$google$entities, options = list(pageLength = 5, scrollX = TRUE), class = 'cell-border stripe')
    })

    output$google_pages <- renderDT({
      if (!is.null(rv$web_results$google$pages) && nrow(rv$web_results$google$pages) > 0)
        datatable(rv$web_results$google$pages, options = list(pageLength = 5, scrollX = TRUE), class = 'cell-border stripe')
    })

    output$bing_pages <- renderDT({
      if (!is.null(rv$web_results$bing$pages) && nrow(rv$web_results$bing$pages) > 0)
        datatable(rv$web_results$bing$pages, options = list(pageLength = 5, scrollX = TRUE), class = 'cell-border stripe')
    })

    output$summary_local <- renderPrint({
      if (!is.null(rv$last_matches) && nrow(rv$last_matches) > 0)
        cat(paste("🌿 Local AI:", rv$last_matches$scientific_name[1],
                  "(", round(rv$last_matches$confidence[1], 1), "%)"))
      else cat("🌿 Local AI: No identification yet")
    })

    output$summary_google <- renderPrint({
      if (!is.null(rv$web_results$google$best_guess))
        cat(paste("🔍 Google Lens:", rv$web_results$google$best_guess))
      else cat("🔍 Google Lens: Not available (API key required)")
    })

    output$summary_bing <- renderPrint({
      if (!is.null(rv$web_results$bing$best_name))
        cat(paste("🖼️ Bing Visual:", rv$web_results$bing$best_name))
      else cat("🖼️ Bing Visual: Not available (API key required)")
    })
  })

  observeEvent(input$wiki_link, {
    if (!is.null(rv$web_results$wiki$url)) browseURL(rv$web_results$wiki$url)
  })

  observeEvent(input$save_species, {
    req(input$new_sci, input$new_image, rv$model)

    toastr_info("Extracting embedding from reference image...", position = "top-right")

    emb <- tryCatch(extract_embedding(rv$model, input$new_image$datapath), error = function(e) {
      toastr_error(paste("Error:", e$message), position = "top-right")
      NULL
    })

    if (is.null(emb)) {
      output$db_status <- renderPrint(cat("❌ Error: Could not extract embedding."))
      return()
    }

    upsert_species(input$new_sci, input$new_common, input$new_family,
                   input$new_habitat, input$new_region, input$new_conserv, emb)
    update_species_table()
    update_stats()
    output$db_status <- renderPrint(cat(sprintf("✅ Species '%s' saved successfully.", input$new_sci)))
    toastr_success(sprintf("Species '%s' added to database", input$new_sci), position = "top-right")

    updateTextInput(session, "new_sci", value = "")
    updateTextInput(session, "new_common", value = "")
    updateTextInput(session, "new_family", value = "")
    updateTextInput(session, "new_habitat", value = "")
    updateTextInput(session, "new_region", value = "")
  })
}

# Run app --------------------------------------------------------------------
shinyApp(ui, server)
