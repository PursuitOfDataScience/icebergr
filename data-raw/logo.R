# Generates man/figures/logo.svg and man/figures/logo.png.
#
# Hand-rolled rather than hexSticker/magick: neither is installed on the machine
# this was drawn on, and there is no SVG rasteriser either, so the PNG comes off
# R's own cairo device. One geometry definition below feeds both writers, so the
# two files cannot drift.
#
# The artwork is original. Apache Iceberg's own logo is neither used nor
# imitated -- see inst/NOTICE.

# ---- geometry (SVG convention: y grows downwards) -------------------------
W  <- 1200                       # flat-to-flat width, the R hex sticker standard
H  <- W * 2 / sqrt(3)            # 1385.64: point-to-point height
CX <- W / 2
Q  <- H / 4                      # y of the upper two vertices

HEX <- list(x = c(CX, W, W,     CX, 0,     0),
            y = c(0,  Q, H - Q, H,  H - Q, Q))

Y_WATER <- 620

# Above the waterline: three planes off one peak, plus a shoulder, so it reads
# as faceted ice rather than a cone.
TIP_SHADE <- list(x = c(596, 478, 428, 596), y = c(352, 470, Y_WATER, Y_WATER))
TIP_MID   <- list(x = c(596, 690, 596),      y = c(352, 478, Y_WATER))
TIP_LIT   <- list(x = c(596, 690, 748, 800, 596),
                  y = c(352, 478, 432, Y_WATER, Y_WATER))

# Below it: wider and deeper than the tip, which is the whole metaphor.
KEEL <- list(
  x = c(428, 300, 238, 252, 348, 500, 668, 806, 884, 896, 800),
  y = c(Y_WATER, 672, 760, 868, 960, 1000, 1000, 952, 858, 742, Y_WATER)
)
KEEL_LIT <- list(
  x = c(596, 800, 896, 884, 806, 668, 560),
  y = c(Y_WATER, Y_WATER, 742, 858, 952, 1000, 1000)
)
KEEL_SHADE <- list(
  x = c(596, 560, 500, 348, 252, 238, 300, 428),
  y = c(Y_WATER, 1000, 1000, 960, 868, 760, 672, Y_WATER)
)

STRATA <- c(690, 760, 830, 900, 962)   # snapshots, stacked

STARS <- data.frame(
  x = c(206, 322, 268, 438, 966, 892, 1024, 812, 700, 156, 392, 944, 520, 1080),
  y = c(268, 176, 402, 118, 214, 372, 452,  156, 96,  452, 288, 118, 210, 300),
  r = c(6.5, 4.5, 5.5, 4,   6,   5,   4.5,  4,   5.5, 4,   3.5, 3,   4,   5),
  a = c(.85, .55, .70, .45, .80, .60, .50,  .45, .65, .40, .40, .35, .50, .55)
)

# ---- palette --------------------------------------------------------------
SKY_TOP <- "#030D18"; SKY_BOT <- "#14476F"
SEA_TOP <- "#0A3453"; SEA_BOT <- "#01080F"
ICE_LIT <- "#F4FBFF"; ICE_MID <- "#D8EFFC"; ICE_SHADE <- "#A9D3EE"
KEEL_L  <- "#6FD4F0"; KEEL_S  <- "#3E9FCB"; KEEL_ALPHA <- 0.62
EDGE    <- "#8FE3FF"; INK     <- "#F4FBFF"

# ---- helpers --------------------------------------------------------------
lerp_hex <- function(a, b, t) {
  a <- col2rgb(a); b <- col2rgb(b)
  rgb(a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t,
      a[3] + (b[3] - a[3]) * t, maxColorValue = 255)
}

# Sutherland-Hodgman: clip any subject polygon to a convex one. Holds the
# gradient bands inside the hex and the strata inside the ice.
#
# The winding is settled by testing the clip polygon's own centroid rather than
# by a signed-area formula -- the sign of that formula depends on whether y
# grows up or down, and getting it backwards clips every shape to nothing
# instead of failing loudly.
clip_convex <- function(subj, clip) {
  side <- function(px, py, ax, ay, bx, by)
    (bx - ax) * (py - ay) - (by - ay) * (px - ax)
  cxy <- c(mean(clip$x), mean(clip$y))
  if (side(cxy[1], cxy[2], clip$x[1], clip$y[1], clip$x[2], clip$y[2]) < 0)
    clip <- list(x = rev(clip$x), y = rev(clip$y))

  n <- length(clip$x)
  for (i in seq_len(n)) {
    if (!length(subj$x)) return(subj)
    j <- if (i == n) 1L else i + 1L
    ax <- clip$x[i]; ay <- clip$y[i]; bx <- clip$x[j]; by <- clip$y[j]
    ox <- numeric(0); oy <- numeric(0)
    m <- length(subj$x)
    for (k in seq_len(m)) {
      l <- if (k == m) 1L else k + 1L
      px <- subj$x[k]; py <- subj$y[k]; qx <- subj$x[l]; qy <- subj$y[l]
      d1 <- side(px, py, ax, ay, bx, by)
      d2 <- side(qx, qy, ax, ay, bx, by)
      if (d1 >= 0) { ox <- c(ox, px); oy <- c(oy, py) }
      if ((d1 >= 0) != (d2 >= 0)) {
        t <- d1 / (d1 - d2)
        ox <- c(ox, px + (qx - px) * t); oy <- c(oy, py + (qy - py) * t)
      }
    }
    subj <- list(x = ox, y = oy)
  }
  subj
}

band <- function(y0, y1) list(x = c(-60, W + 60, W + 60, -60), y = c(y0, y0, y1, y1))
pts  <- function(p) paste(sprintf("%.1f,%.1f", p$x, p$y), collapse = " ")

stopifnot(length(clip_convex(band(0, H), HEX)$x) > 0)   # the bug above, caught

# ---- SVG ------------------------------------------------------------------
poly <- function(p, fill, extra = "")
  sprintf('<polygon points="%s" fill="%s"%s/>', pts(p), fill, extra)

writeLines(c(
  sprintf('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%.0f" viewBox="0 0 %d %.4f" role="img" aria-label="icebergr">', W, H, W, H),
  '<defs>',
  sprintf('<linearGradient id="sky" x1="0" y1="0" x2="0" y2="%.1f" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>', Y_WATER, SKY_TOP, SKY_BOT),
  sprintf('<linearGradient id="sea" x1="0" y1="%.1f" x2="0" y2="%.4f" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>', Y_WATER, H, SEA_TOP, SEA_BOT),
  sprintf('<clipPath id="hex"><polygon points="%s"/></clipPath>', pts(HEX)),
  sprintf('<clipPath id="keel"><polygon points="%s"/></clipPath>', pts(KEEL)),
  '</defs>',
  '<g clip-path="url(#hex)">',
  sprintf('<rect x="0" y="0" width="%d" height="%.1f" fill="url(#sky)"/>', W, Y_WATER),
  sprintf('<rect x="0" y="%.1f" width="%d" height="%.4f" fill="url(#sea)"/>', Y_WATER, W, H - Y_WATER),
  paste0(sprintf('<circle cx="%.0f" cy="%.0f" r="%.1f" fill="%s" opacity="%.2f"/>',
                 STARS$x, STARS$y, STARS$r, INK, STARS$a), collapse = ""),
  sprintf('<g opacity="%.2f">%s%s</g>', KEEL_ALPHA,
          poly(KEEL_LIT, KEEL_L), poly(KEEL_SHADE, KEEL_S)),
  sprintf('<g clip-path="url(#keel)" stroke="%s" stroke-width="7" opacity="0.3">%s</g>',
          INK, paste0(sprintf('<line x1="0" y1="%.0f" x2="%d" y2="%.0f"/>', STRATA, W, STRATA), collapse = "")),
  poly(TIP_SHADE, ICE_SHADE), poly(TIP_MID, ICE_MID), poly(TIP_LIT, ICE_LIT),
  sprintf('<line x1="0" y1="%.1f" x2="%d" y2="%.1f" stroke="%s" stroke-width="6" opacity="0.8"/>', Y_WATER, W, Y_WATER, EDGE),
  sprintf('<text x="%d" y="1158" fill="%s" font-family="Space Grotesk, DejaVu Sans, sans-serif" font-size="126" font-weight="700" letter-spacing="8" text-anchor="middle">icebergr</text>', CX, INK),
  '</g>',
  sprintf('<polygon points="%s" fill="none" stroke="%s" stroke-width="22"/>', pts(HEX), EDGE),
  '</svg>'
), "man/figures/logo.svg")

# ---- PNG ------------------------------------------------------------------
# cairo cannot clip to a polygon, so full-width shapes are clipped to the hex
# here instead and the gradients become bands. Drawing happens on a y-up axis
# with fy() flipping the SVG coordinates: text adj and strheight both take their
# sign from the axis, so a reversed one silently breaks them.
fy   <- function(y) H - y
fill <- function(p, col) polygon(p$x, fy(p$y), col = col, border = NA)

png("man/figures/logo.png", width = W, height = round(H), bg = "transparent",
    type = "cairo-png", antialias = "subpixel", pointsize = 126)
op <- par(mar = rep(0, 4), xaxs = "i", yaxs = "i", family = "Space Grotesk", font = 2)
plot.new(); plot.window(xlim = c(0, W), ylim = c(0, H), asp = 1)

NB <- 110
for (i in seq_len(NB)) {                                   # sky, then sea
  b <- clip_convex(band((i - 1) / NB * Y_WATER, i / NB * Y_WATER + 1), HEX)
  if (length(b$x)) fill(b, lerp_hex(SKY_TOP, SKY_BOT, (i - .5) / NB))
}
for (i in seq_len(NB)) {
  y0 <- Y_WATER + (i - 1) / NB * (H - Y_WATER)
  b <- clip_convex(band(y0, y0 + (H - Y_WATER) / NB + 1), HEX)
  if (length(b$x)) fill(b, lerp_hex(SEA_TOP, SEA_BOT, (i - .5) / NB))
}
for (i in seq_len(nrow(STARS)))
  symbols(STARS$x[i], fy(STARS$y[i]), circles = STARS$r[i], inches = FALSE,
          add = TRUE, bg = adjustcolor(INK, STARS$a[i]), fg = NA)

fill(KEEL_LIT,   adjustcolor(KEEL_L, KEEL_ALPHA))
fill(KEEL_SHADE, adjustcolor(KEEL_S, KEEL_ALPHA))
for (y in STRATA) {
  b <- clip_convex(band(y - 3.5, y + 3.5), KEEL)
  if (length(b$x)) fill(b, adjustcolor(INK, 0.30))
}

fill(TIP_SHADE, ICE_SHADE); fill(TIP_MID, ICE_MID); fill(TIP_LIT, ICE_LIT)

wl <- clip_convex(band(Y_WATER - 3, Y_WATER + 3), HEX)
if (length(wl$x)) fill(wl, adjustcolor(EDGE, 0.8))

# Tracked-out wordmark, a character at a time. pointsize = 126 at the png
# device's default 72 dpi makes cex = 1 exactly the SVG's font-size.
lab   <- strsplit("icebergr", "")[[1]]
track <- 8
wch   <- vapply(lab, strwidth, numeric(1), units = "user")
xc    <- CX - (sum(wch) + track * (length(lab) - 1)) / 2
for (i in seq_along(lab)) {
  text(xc, fy(1158), lab[i], adj = c(0, 0), col = INK)
  xc <- xc + wch[i] + track
}

polygon(HEX$x, fy(HEX$y), border = EDGE, lwd = 22 / 0.75, col = NA)  # lwd is 1/96"
par(op); invisible(dev.off())

cat(sprintf("logo.svg %s bytes\nlogo.png %s bytes\n",
            format(file.size("man/figures/logo.svg"), big.mark = ","),
            format(file.size("man/figures/logo.png"), big.mark = ",")))
