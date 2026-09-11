# ==============================================================================
# assert_fresh() - shared freshness-enforcement mechanism (2026-09-08 rebuild)
#
# Root cause this exists to fix: the 2026-09-07 incident (stale ward
# shapefile let a draw select from already-inaccessible wards), and at least
# five more instances of the same shape found in the pipeline audit - a
# "current status" artifact gets built once by a standalone script, then read
# elsewhere as if live, with nothing checking it's actually current. Comments
# asking a human to "remember to rerun X first" are not enforcement; this is.
#
# Two modes, chosen per-artifact by whether regenerating it is a safe,
# deterministic, no-judgment operation or not (see 1_sampling/CLAUDE.md's
# rebuild design notes for the classification of every current artifact):
#   - mode = "auto": artifact is stale -> call fix_fn() automatically, print
#     what happened, re-verify, then continue. Only ever used for pure
#     copies/regenerations with no side effects (accessibility mirror sync,
#     real_submissions.csv mirror, deletion-log ingestion).
#   - mode = "stop": artifact is stale -> stop() with the exact fix command
#     printed, never runs anything itself. Used for anything that writes into
#     judgment-sensitive state, is explicitly "don't rerun casually," or is a
#     heavy standalone recompute (ward shapefile, IDP site frame, staged
#     household stamping, anything touching the deletion tracker).
#
# Does NOT trust existing "_*_version.txt" stamp files as ground truth - they
# can themselves go stale (found exactly this: 2026-09-07's accessibility
# stamp still said the ward shapefile was from 09-03, three days after it was
# actually rebuilt, because writing the stamp was a separate manual step
# nobody remembered mid-incident). Always compares real, current mtime/hash.
# Writes the stamp file itself as a side effect of a successful check, so the
# stamp becomes trustworthy *because* this function maintains it, not because
# some other script remembers to.
# ==============================================================================
suppressPackageStartupMessages(library(tools))

.af_file_state <- function(path) {
  if (!file.exists(path)) return(NULL)
  list(mtime = file.info(path)$mtime, md5 = tools::md5sum(path))
}

#' @param artifact_path Path to the file that must be fresh.
#' @param source_paths Character vector of path(s) the artifact must not
#'   predate. Any of these missing is an error (can't check freshness against
#'   a source that doesn't exist).
#' @param mode "auto" (safe to regenerate automatically) or "stop" (never
#'   regenerate automatically, just block with instructions).
#' @param fix_fn For mode="auto": a zero-arg function that regenerates/syncs
#'   the artifact. Called, then the artifact is re-checked - if still stale
#'   after fix_fn() runs, that's a real error (fix_fn() itself is broken),
#'   not silently swallowed.
#' @param fix_hint For mode="stop": a human-readable string, the exact
#'   command to run. Printed in the stop() message.
#' @param stamp_path Optional - where to write/update the version-stamp file
#'   for this artifact after a successful check. Omit to skip stamping.
#' @param label Optional short name for this artifact, used in messages and
#'   as the stamp file's key prefix. Defaults to the artifact's basename.
assert_fresh <- function(artifact_path, source_paths, mode = c("auto", "stop"),
                          fix_fn = NULL, fix_hint = NULL, stamp_path = NULL,
                          label = NULL) {
  mode <- match.arg(mode)
  if (is.null(label)) label <- basename(artifact_path)
  missing_sources <- source_paths[!file.exists(source_paths)]
  if (length(missing_sources) > 0) {
    stop(sprintf(
      "assert_fresh(%s): source file(s) do not exist, cannot check freshness: %s",
      label, paste(missing_sources, collapse = ", ")
    ))
  }

  check_stale <- function() {
    art <- .af_file_state(artifact_path)
    if (is.null(art)) return(TRUE)  # artifact doesn't exist at all = stale
    source_mtimes <- vapply(source_paths, function(p) as.numeric(.af_file_state(p)$mtime), numeric(1))
    art$mtime < max(source_mtimes)
  }

  stale <- check_stale()

  if (stale && mode == "stop") {
    newest_source <- source_paths[which.max(vapply(source_paths, function(p) as.numeric(.af_file_state(p)$mtime), numeric(1)))]
    stop(sprintf(
      paste0(
        "assert_fresh(%s): STALE - this predates its source (%s) and this ",
        "project's convention is to never auto-regenerate this one (judgment-",
        "sensitive or explicitly not-casual-to-rerun). Run this first, then ",
        "re-run whatever you were doing:\n\n    %s\n"
      ),
      label, newest_source, if (!is.null(fix_hint)) fix_hint else "(no fix_hint provided - see the artifact's own build script)"
    ))
  }

  if (stale && mode == "auto") {
    if (is.null(fix_fn)) {
      stop(sprintf("assert_fresh(%s): STALE and mode='auto' but no fix_fn provided.", label))
    }
    cat(sprintf("assert_fresh(%s): stale, auto-fixing...\n", label))
    fix_fn()
    if (check_stale()) {
      stop(sprintf(
        "assert_fresh(%s): still stale after fix_fn() ran - the regeneration itself is broken, not a freshness gap. Investigate fix_fn(), don't retry.",
        label
      ))
    }
    cat(sprintf("assert_fresh(%s): refreshed from %s.\n", label, paste(basename(source_paths), collapse = ", ")))
  }

  if (!stale) {
    cat(sprintf("assert_fresh(%s): fresh, no action needed.\n", label))
  }

  if (!is.null(stamp_path)) {
    art <- .af_file_state(artifact_path)
    lines <- c(
      sprintf("stamped_at: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
      sprintf("artifact_path: %s", artifact_path),
      sprintf("artifact_mtime: %s", format(art$mtime, "%Y-%m-%d %H:%M:%S")),
      sprintf("artifact_md5: %s", art$md5),
      sprintf("checked_against_sources: %s", paste(source_paths, collapse = "; "))
    )
    writeLines(lines, stamp_path)
  }

  invisible(!stale)
}
