suppressPackageStartupMessages({library(dplyr); library(readr)})
setwd("c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring")
source("reports/partner_data_recovery/scripts/issue_tracker.R")
source("reports/partner_data_recovery/scripts/fallback_resolvers.R")

REAL_PATH <- TRACKER_PATH
SCRATCH_PATH <- normalizePath("_working_files/scratch_fallback_test/scratch_tracker.csv")
real_before <- read_csv(REAL_PATH, show_col_types = FALSE, col_types = cols(.default = "c"))

# ---- redirect the tracker to the scratch copy for this whole test ----------
TRACKER_PATH <- SCRATCH_PATH
cat("TRACKER_PATH now points to:", TRACKER_PATH, "\n\n")

before <- read_tracker()
cat("scratch tracker rows before:", nrow(before), "\n")

cat("\n==== STEP 1: apply_fallback_sweep(confirm = TRUE) on the scratch copy ====\n")
res1 <- apply_fallback_sweep(confirm = TRUE, log_dir = "_working_files/scratch_fallback_test/_log")
after1 <- read_tracker()
stopifnot(nrow(after1) == nrow(before))
n_applied <- sum(!is.na(after1$fallback_status) & nzchar(after1$fallback_status))
cat(sprintf("rows with fallback_status set after apply: %d\n", n_applied))

cat("\n==== STEP 2: verify apply touched ONLY the 4 fallback_* columns ====\n")
other_cols <- setdiff(TRACKER_COLUMNS, c("fallback_status", "fallback_mechanism", "fallback_resolution", "fallback_applied_date"))
diffs <- sapply(other_cols, function(col) sum(before[[col]] != after1[[col]] | (is.na(before[[col]]) != is.na(after1[[col]])), na.rm = TRUE))
print(diffs[diffs > 0])
if (all(diffs == 0)) cat("OK: no column other than the 4 fallback_* columns changed.\n") else stop("FAIL: apply_fallback_sweep changed a column it should not have.")

cat("\n==== STEP 3: pick one fallback-applied row and simulate a LATE real partner response ====\n")
target <- after1$issue_id[!is.na(after1$fallback_status) & after1$fallback_status == "applied_candidate"][1]
cat("target issue_id:", target, "\n")
cat("before partner response - status:", after1$status[after1$issue_id == target],
    "fallback_status:", after1$fallback_status[after1$issue_id == target], "\n")
ok <- apply_resolution(target, "confirmed", resolution = "TEST: partner confirmed the real household after all.",
                        confirmed_by = "partner")
stopifnot(isTRUE(ok))
after2 <- read_tracker()
cat("after partner response - status:", after2$status[after2$issue_id == target],
    "confirmed_by:", after2$confirmed_by[after2$issue_id == target],
    "fallback_status (should be UNCHANGED, still applied_candidate):", after2$fallback_status[after2$issue_id == target], "\n")
stopifnot(after2$status[after2$issue_id == target] == "confirmed")
stopifnot(after2$fallback_status[after2$issue_id == target] == "applied_candidate")
cat("OK: a real partner response was NOT blocked by a prior fallback application, and left fallback_status as a historical record.\n")

cat("\n==== STEP 4: re-run apply_fallback_sweep() - should be idempotent (only fills genuinely new gaps) ====\n")
res2 <- apply_fallback_sweep(confirm = TRUE, log_dir = "_working_files/scratch_fallback_test/_log")
after3 <- read_tracker()
# every row that had a fallback_status after step 1 should be byte-identical now (step 2's target aside, which is now terminal & excluded from the sweep entirely)
prev_applied <- after1$issue_id[!is.na(after1$fallback_status) & nzchar(after1$fallback_status)]
changed <- 0
for (col in c("fallback_status","fallback_mechanism","fallback_resolution","fallback_applied_date")) {
  idx <- match(prev_applied, after3$issue_id)
  changed <- changed + sum(after1[[col]][match(prev_applied, after1$issue_id)] != after3[[col]][idx], na.rm = TRUE)
}
cat(sprintf("columns changed among rows already processed in step 1: %d (expect 0)\n", changed))
if (changed == 0) cat("OK: second sweep did not overwrite already-applied rows.\n") else stop("FAIL: second sweep overwrote existing fallback data.")

cat("\n==== STEP 5: restore_fallback_sweep() using step 1's snapshot ====\n")
cat("snapshot used:", res1$snapshot, "\n")
n_restored <- restore_fallback_sweep(res1$snapshot, log_dir = "_working_files/scratch_fallback_test/_log")
after4 <- read_tracker()
restored_ids <- read_csv(res1$snapshot, show_col_types = FALSE, col_types = cols(.default = "c"))$issue_id
still_set <- sum(!is.na(after4$fallback_status[match(restored_ids, after4$issue_id)]) & nzchar(after4$fallback_status[match(restored_ids, after4$issue_id)]))
cat(sprintf("of %d restored issue_ids, %d still have a non-blank fallback_status after restore (expect 0, EXCEPT the partner-confirmed target - restore only touches fallback_* columns, never status)\n", length(restored_ids), still_set))
cat("target's status after restore (should still be 'confirmed', untouched by restore):", after4$status[after4$issue_id == target], "\n")
stopifnot(after4$status[after4$issue_id == target] == "confirmed")
target_fb <- after4$fallback_status[after4$issue_id == target]
cat("target's fallback_status after restore (should be blank/NA again):", ifelse(is.na(target_fb) || !nzchar(target_fb), "blank - OK", target_fb), "\n")

cat("\n==== STEP 6: confirm the REAL live tracker was never touched throughout this test ====\n")
real_after <- read_csv(REAL_PATH, show_col_types = FALSE, col_types = cols(.default = "c"))
cat("real tracker row count before:", nrow(real_before), " after:", nrow(real_after), "\n")
cat("real tracker identical:", identical(as.data.frame(real_before), as.data.frame(real_after)), "\n")
stopifnot(identical(as.data.frame(real_before), as.data.frame(real_after)))
cat("\nALL SCRATCH TESTS PASSED.\n")
