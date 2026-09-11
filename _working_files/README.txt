Working files for the Achieved-definition redesign (started 2026-09-10).

Everything in here is disposable ad hoc analysis output and verification
material, not production code — safe to delete this whole folder once the
redesign is finished and signed off. Production code this work produced
lives at cleaning/real/audit_duration.R (and its cache,
cleaning/real/audit_duration_cache.csv), which stay in their normal place,
not here.

Contents:
- duplicate_examples_for_do.csv / duplicate_pair_examples_for_do.csv —
  is_duplicate vs the DO's duplicate_point comparison, for tomorrow's DO
  conversation.
- duration_audit_verification.csv — full disputed-set comparison of DO vs
  naive vs real audit-based duration.
- surprising_bucket_full.csv — the ~647 submissions where naive and the DO
  had already agreed "not short" but the real audit duration disagrees.
- duration_verification_examples/ — 3 real audit.csv files plus a README
  showing the exact row-by-row math, for Jack to hand-verify the duration
  calculation before signing off.
- scripts/ — the throwaway R scripts used to produce the above, kept for
  transparency/reruns, not meant to be maintained.
