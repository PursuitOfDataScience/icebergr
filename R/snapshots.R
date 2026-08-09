# Snapshot history and time travel.

#' Snapshot history of an Iceberg table
#'
#' @param tbl An `icebergr_table` from [icebergr_table()].
#'
#' @return A tibble of snapshots, oldest first, with columns:
#'   \describe{
#'     \item{`snapshot_id`}{Character. See the note on ids below.}
#'     \item{`parent_snapshot_id`}{Character, `NA` for the first snapshot.}
#'     \item{`sequence_number`}{Numeric.}
#'     \item{`timestamp`}{`POSIXct` in UTC, when the snapshot was committed.}
#'     \item{`operation`}{`"append"`, `"overwrite"`, `"replace"` or `"delete"`.}
#'     \item{`schema_id`}{Integer, the schema in force for that snapshot.}
#'     \item{`added_records`, `total_records`}{Numeric, from the snapshot
#'       summary, `NA` when the writer did not record them.}
#'     \item{`summary`}{The full snapshot summary as a JSON string.}
#'     \item{`manifest_list`}{Path to the snapshot's manifest list.}
#'   }
#'
#' @section Snapshot ids are character:
#' Iceberg assigns snapshot ids as random 64-bit integers, and R's numeric type
#' holds only 53 bits of integer precision. A large id passed through a double
#' would come back subtly altered and then silently select the wrong snapshot, so
#' ids are character throughout, and [icebergr_scan()] accepts them as such.
#'
#' @examples
#' # Two appends, so there is history to travel through.
#' tbl <- icebergr_example_table(rows = 10)
#'
#' history <- icebergr_snapshots(tbl)
#' history[, c("snapshot_id", "operation", "added_records", "total_records")]
#'
#' # Read the table as it was at its first snapshot.
#' icebergr_collect(icebergr_scan(tbl, snapshot_id = history$snapshot_id[[1]]))
#' @export
icebergr_snapshots <- function(tbl) {
  check_table(tbl)
  raw <- rs_table_snapshots(tbl$ptr)

  out <- tibble::tibble(
    snapshot_id = raw$snapshot_id,
    parent_snapshot_id = raw$parent_snapshot_id,
    sequence_number = raw$sequence_number,
    timestamp = as.POSIXct(raw$timestamp_ms / 1000, origin = "1970-01-01", tz = "UTC"),
    operation = raw$operation,
    schema_id = raw$schema_id,
    added_records = summary_number(raw$summary, "added-records"),
    total_records = summary_number(raw$summary, "total-records"),
    summary = raw$summary,
    manifest_list = raw$manifest_list
  )
  out
}

# The snapshot summary is free-form, so the two counts worth surfacing are
# pulled out with a targeted match rather than by parsing the whole thing.
#' @noRd
summary_number <- function(summaries, key) {
  pattern <- paste0('"', key, '"\\s*:\\s*"?([0-9]+)"?')
  vapply(
    summaries,
    function(s) {
      m <- regmatches(s, regexec(pattern, s))[[1L]]
      if (length(m) < 2L) NA_real_ else as.numeric(m[[2L]])
    },
    numeric(1),
    USE.NAMES = FALSE
  )
}

#' Resolve a timestamp to the snapshot that was current at that moment
#'
#' Iceberg's scan API takes a snapshot id, not a timestamp, so `as_of` is
#' resolved here against the snapshot history: the newest snapshot committed at
#' or before `as_of`.
#' @noRd
snapshot_as_of <- function(tbl, as_of, call = rlang::caller_env()) {
  if (!inherits(as_of, "POSIXt") && !inherits(as_of, "Date")) {
    abort("`as_of` must be a POSIXct or Date.", call = call)
  }
  if (length(as_of) != 1L || is.na(as_of)) {
    abort("`as_of` must be a single non-missing time.", call = call)
  }

  history <- icebergr_snapshots(tbl)
  if (nrow(history) == 0L) {
    abort(
      c(
        "This table has no snapshots, so it cannot be read as of a past time.",
        i = "A table has no snapshots until something has been written to it."
      ),
      call = call
    )
  }

  target <- as.POSIXct(as_of, tz = "UTC")
  eligible <- history[history$timestamp <= target, , drop = FALSE]

  if (nrow(eligible) == 0L) {
    abort(
      c(
        paste0(
          "The table has no snapshot at or before ",
          format(target, "%Y-%m-%d %H:%M:%S", tz = "UTC"), " UTC."
        ),
        i = paste0(
          "Its earliest snapshot is ",
          format(min(history$timestamp), "%Y-%m-%d %H:%M:%S", tz = "UTC"), " UTC."
        )
      ),
      call = call
    )
  }

  eligible$snapshot_id[[nrow(eligible)]]
}
