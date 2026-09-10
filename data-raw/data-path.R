# Generates man/figures/data-path.png and .svg -- the diagram that replaces the
# README's paragraphs about pushdown and the Arrow interchange layer.
#
# Same approach as data-raw/logo.R: one geometry definition, two writers, no
# rasteriser needed. The README references the PNG, so the picture does not
# depend on the reader having any particular font.

W <- 1200
H <- 494

BG_TOP <- "#04131F"
BG_BOT <- "#0A2A45"
PANEL <- "#0C2B45"
STROKE <- "#1E4E75"
INK <- "#EAF5FC"
MUTED <- "#8FB6D1"
CYAN <- "#6FD4F0"
DIM <- "#12354F"
DIMS <- "#28536F"
HOT <- "#12405C"

SANS <- "Space Grotesk, ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
MONO <- "ui-monospace, SFMono-Regular, Menlo, Consolas, DejaVu Sans Mono, monospace"

CODE <- 'icebergr_scan(tbl, filter = amount > 900, select = c("id", "amount"))'
STEPS <- c("plan the scan", "prune files, then row groups", "decode what survived")
FILES <- c(FALSE, TRUE, FALSE, FALSE, TRUE, FALSE) # which of the six get read
RETURN <- "Arrow C stream  →  nanoarrow  →  tibble        no copy, no serialisation"

# ---- layout (y measured downwards; text y values are baselines) -----------
X0 <- 40
CW <- 1080
CHIP <- list(y = 52, h = 58)
DOWN <- c(128, 166)
ROW2 <- list(y = 208, h = 54, x = X0 + c(0, 369, 738), w = c(341, 341, 342))
ROW3 <- list(y = 308, h = 62, x = X0 + (0:5) * 184, w = 160)
BACK <- list(y = 418, h = 54)

svg <- character(0)
add <- function(...) svg <<- c(svg, sprintf(...))

# ---- SVG ------------------------------------------------------------------
add('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-label="A scan filter is pushed down into iceberg-rust, which reads two of six data files and returns Arrow to R">', W, H, W, H)
add('<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="%d" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient></defs>', H, BG_TOP, BG_BOT)
add('<rect x="0" y="0" width="%d" height="%d" rx="18" fill="url(#bg)"/>', W, H)
add("<style>.s{font-family:%s}.m{font-family:%s}</style>", SANS, MONO)

cap <- function(x, y, s) add('<text class="s" x="%d" y="%d" fill="%s" font-size="19" font-weight="600" letter-spacing="2.5">%s</text>', x, y, MUTED, s)
chip <- function(x, y, w, h, fill, stroke, dash = FALSE) {
  add(
    '<rect x="%.0f" y="%d" width="%.0f" height="%d" rx="10" fill="%s" stroke="%s" stroke-width="2"%s/>',
    x, y, w, h, fill, stroke, if (dash) ' stroke-dasharray="7 6"' else ""
  )
}
note <- function(x, y, s, col = CYAN, anchor = "start") {
  add('<text class="s" x="%.0f" y="%d" fill="%s" font-size="20" text-anchor="%s">%s</text>', x, y, col, anchor, s)
}

cap(X0, 34, "R")
chip(X0, CHIP$y, CW, CHIP$h, PANEL, STROKE)
add(
  '<text class="m" x="%d" y="%d" fill="%s" font-size="23">%s</text>',
  X0 + 24, CHIP$y + 38, INK, gsub('"', "&quot;", CODE)
)

add('<g stroke="%s" stroke-width="2.5" fill="none" stroke-linecap="round"><path d="M540 %d V%d"/><path d="M531 %d l9 9 9 -9"/></g>', CYAN, DOWN[1], DOWN[2], DOWN[2] - 9)
note(566, mean(DOWN) + 7, "the filter and the column list go with it")

cap(X0, 190, "ICEBERG-RUST 0.10")
for (i in seq_along(STEPS)) {
  chip(ROW2$x[i], ROW2$y, ROW2$w[i], ROW2$h, PANEL, STROKE)
  add(
    '<text class="s" x="%.0f" y="%d" fill="%s" font-size="21" text-anchor="middle">%s</text>',
    ROW2$x[i] + ROW2$w[i] / 2, ROW2$y + 35, INK, STEPS[i]
  )
  if (i < 3) {
    add(
      '<path d="M%.0f %d l11 8 -11 8" fill="none" stroke="%s" stroke-width="2.5" stroke-linecap="round"/>',
      ROW2$x[i] + ROW2$w[i] + 8, ROW2$y + 19, CYAN
    )
  }
}

cap(X0, 290, "ICEBERG TABLE · SIX DATA FILES")
for (i in seq_along(FILES)) {
  h <- FILES[i]
  chip(ROW3$x[i], ROW3$y, ROW3$w, ROW3$h, if (h) HOT else DIM, if (h) CYAN else DIMS, dash = !h)
  for (k in 0:2) {
    add(
      '<rect x="%.0f" y="%d" width="%.0f" height="6" rx="3" fill="%s" opacity="%.2f"/>',
      ROW3$x[i] + 18, ROW3$y + 15 + k * 14, ROW3$w - 36,
      if (h) CYAN else MUTED, if (h) c(0.95, 0.3, 0.95)[k + 1] else 0.18
    )
  }
}
note(
  X0, ROW3$y + ROW3$h + 32,
  "two files read, four skipped — and within those two, only the row groups the filter can match", MUTED
)

chip(X0, BACK$y, CW, BACK$h, PANEL, CYAN)
add(
  '<path d="M%d %d l10 -14 10 14" fill="none" stroke="%s" stroke-width="2.5" stroke-linecap="round"/>',
  X0 + 26, BACK$y + 34, CYAN
)
add('<text class="s" x="%d" y="%d" fill="%s" font-size="21">%s</text>', X0 + 74, BACK$y + 35, INK, RETURN)
add("</svg>")
writeLines(svg, "man/figures/data-path.svg")

# ---- PNG ------------------------------------------------------------------
fy <- function(y) H - y

# Corners traced in one continuous sweep. Building them as four independent
# arcs leaves the polygon zig-zagging between opposite corners.
roundrect <- function(x, y, w, h, r, col, border, lwd = 2, lty = 1) {
  a <- function(cx, cy, from, to) {
    t <- seq(from, to, length.out = 14)
    cbind(cx + r * cos(t), cy + r * sin(t))
  }
  p <- rbind(
    a(x + w - r, y + r, -pi / 2, 0), # top-right
    a(x + w - r, y + h - r, 0, pi / 2), # bottom-right
    a(x + r, y + h - r, pi / 2, pi), # bottom-left
    a(x + r, y + r, pi, 3 * pi / 2)
  )
  polygon(p[, 1], fy(p[, 2]), col = col, border = border, lwd = lwd, lty = lty)
}

png("man/figures/data-path.png",
  width = W * 2, height = H * 2, res = 144,
  pointsize = 72, type = "cairo-png", bg = "transparent", antialias = "subpixel"
)
op <- par(mar = rep(0, 4), xaxs = "i", yaxs = "i", family = "Space Grotesk")
plot.new()
plot.window(xlim = c(0, W), ylim = c(0, H), asp = 1)

NB <- 100 # background gradient
ga <- col2rgb(BG_TOP)
gb <- col2rgb(BG_BOT)
for (i in seq_len(NB)) {
  t <- (i - .5) / NB
  y0 <- (i - 1) / NB * H
  rect(0, fy(y0), W, fy(y0 + H / NB + 1),
    border = NA,
    col = rgb(ga[1] + (gb[1] - ga[1]) * t, ga[2] + (gb[2] - ga[2]) * t,
      ga[3] + (gb[3] - ga[3]) * t,
      maxColorValue = 255
    )
  )
}

# pointsize 72 at cex = 1 is 72 user units, so cex is the SVG font-size / 72
say <- function(x, y, s, size, col = INK, adj = 0, fam = "Space Grotesk", fnt = 1) {
  text(x, fy(y), s, adj = c(adj, 0), col = col, cex = size / 72, family = fam, font = fnt)
}
capp <- function(x, y, s) say(x, y, s, 19, MUTED, fnt = 2)

capp(X0, 34, "R")
roundrect(X0, CHIP$y, CW, CHIP$h, 10, PANEL, STROKE)
say(X0 + 24, CHIP$y + 38, CODE, 23, fam = "DejaVu Sans Mono")

lines(c(540, 540), fy(DOWN), col = CYAN, lwd = 2.5)
lines(540 + c(-9, 0, 9), fy(DOWN[2] + c(-9, 0, -9)), col = CYAN, lwd = 2.5)
say(566, mean(DOWN) + 7, "the filter and the column list go with it", 20, CYAN)

capp(X0, 190, "ICEBERG-RUST 0.10")
for (i in seq_along(STEPS)) {
  roundrect(ROW2$x[i], ROW2$y, ROW2$w[i], ROW2$h, 10, PANEL, STROKE)
  say(ROW2$x[i] + ROW2$w[i] / 2, ROW2$y + 35, STEPS[i], 21, adj = .5)
  if (i < 3) {
    lines(ROW2$x[i] + ROW2$w[i] + 8 + c(0, 11, 0),
      fy(ROW2$y + 19 + c(0, 8, 16)),
      col = CYAN, lwd = 2.5
    )
  }
}

capp(X0, 290, "ICEBERG TABLE · SIX DATA FILES")
for (i in seq_along(FILES)) {
  h <- FILES[i]
  roundrect(ROW3$x[i], ROW3$y, ROW3$w, ROW3$h, 10, if (h) HOT else DIM,
    if (h) CYAN else DIMS,
    lty = if (h) 1 else 2
  )
  for (k in 0:2) {
    rect(ROW3$x[i] + 18, fy(ROW3$y + 15 + k * 14),
      ROW3$x[i] + ROW3$w - 18, fy(ROW3$y + 21 + k * 14),
      border = NA,
      col = adjustcolor(
        if (h) CYAN else MUTED,
        if (h) c(0.95, 0.3, 0.95)[k + 1] else 0.18
      )
    )
  }
}
say(
  X0, ROW3$y + ROW3$h + 32,
  "two files read, four skipped — and within those two, only the row groups the filter can match",
  20, MUTED
)

roundrect(X0, BACK$y, CW, BACK$h, 10, PANEL, CYAN)
lines(X0 + 26 + c(0, 10, 20), fy(BACK$y + 34 + c(0, -14, 0)), col = CYAN, lwd = 2.5)
say(X0 + 74, BACK$y + 35, RETURN, 21)

par(op)
invisible(dev.off())
cat(sprintf(
  "data-path.svg %s bytes\ndata-path.png %s bytes\n",
  format(file.size("man/figures/data-path.svg"), big.mark = ","),
  format(file.size("man/figures/data-path.png"), big.mark = ",")
))
