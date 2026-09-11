# NG037 (Zamfara) tool bug — evidence for the data/tool team

## The claim

The deployed KoBo XLSForm has a bug specific to Zamfara (`NG037`): every
Zamfara submission exports with `non_idp_point_id`, `idp_cluster_id`, and
`cluster_id` blank, even though the enumerator selected a real sample
point in the app. No other state is affected.

## 1. Proof in the tool itself

File: `cleaning/MSNA_Data_Cleaning/kobo_tool/NGA2605_MSNA_Kobo_10082026.xlsx`,
sheet `survey`.

Two calculate fields build these values by chaining every state's
per-state answer together with `coalesce()`. Every argument should be
wrapped `${...}` so the form reads that field's *value*. The last
argument in both chains — Zamfara's — is missing the wrapper:

**Row 42, field `idp_cluster_id`:**
```
coalesce(${idp_cluster_NG002}, coalesce(${idp_cluster_NG007}, coalesce(${idp_cluster_NG008},
coalesce(${idp_cluster_NG019}, coalesce(${idp_cluster_NG021}, coalesce(${idp_cluster_NG026},
coalesce(${idp_cluster_NG032}, coalesce(${idp_cluster_NG034}, coalesce(${idp_cluster_NG036},
idp_cluster_NG037))))))))       <-- not wrapped in ${...}
```

**Row 52, field `non_idp_point_id`:**
```
coalesce(${sample_point_NG002_non_idp}, coalesce(${sample_point_NG007_non_idp}, ...
..., coalesce(${sample_point_NG036_non_idp},
sample_point_NG037_non_idp))))))))))   <-- not wrapped in ${...}
```

Every other state (NG002, NG007, NG008, NG019, NG021, NG026, NG032,
NG034, NG036) is correctly wrapped. Zamfara's is the only one that
isn't, in both formulas.

**The fix**: wrap the last argument in each formula —
`idp_cluster_NG037` → `${idp_cluster_NG037}` (row 42) and
`sample_point_NG037_non_idp` → `${sample_point_NG037_non_idp}` (row 52)
— then redeploy the form.

## 2. Proof in the exported data

File: `cleaning/MSNA_Data_Cleaning/output/anonymised_data/NGA2605_MSNA_anonymised_2026-08-14.xlsx`,
sheet `main`.

Every non-IDP submission's `non_idp_point_id`, broken down by state:

| State (`admin1`) | submissions | `non_idp_point_id` blank |
|---|---|---|
| NG021 | 162 | 0 |
| NG034 | 46 | 0 |
| **NG037** | **62** | **62 (100%)** |

Every single Zamfara submission is blank; every submission from every
other state is populated. Same pattern for `idp_cluster_id` on the IDP
side (11/11 Zamfara IDP rows blank).

**Common false positive to watch for**: `non_idp_point_id` is only ever
populated on *non-IDP* submissions by design — every IDP row, in every
state, shows it blank too, which is correct and not this bug. Always
filter to `sample_pop_type_filter == "non_idp"` before checking this
column (and to `"idp"` before checking `idp_cluster_id`) — checking
across all rows without that filter makes NG021/NG034/NG032 look broken
too, when it's really just their IDP rows.

The value is not actually missing — it's sitting one column over, in
the per-state column the broken coalesce() should have picked up.
Example rows (Zamfara, non-IDP):

| `uuid` | `non_idp_point_id` (broken) | `sample_point_NG037_non_idp` (correct value, ignored by the tool) |
|---|---|---|
| `5e5b2397-...` | *blank* | `non_idp_NG037007_9_R03` |
| `eccd475b-...` | *blank* | `non_idp_NG037007_6_HH04` |
| `22ef2aaf-...` | *blank* | `non_idp_NG037007_9_HH16` |

And a working state for contrast (Sokoto, NG034) — `non_idp_point_id`
populated directly, no per-state fallback needed:

| `uuid` | `non_idp_point_id` |
|---|---|
| `558a1358-...` | `non_idp_NG034021_11_HH01` |
| `7aabe408-...` | `non_idp_NG034021_11_HH03` |

## How to reproduce this yourself

In R, against the latest `anonymised_data` export:

```r
library(readxl); library(dplyr)
main <- read_excel("path/to/anonymised_data.xlsx", sheet = "main")

main %>%
  filter(sample_pop_type_filter == "non_idp") %>%
  group_by(admin1) %>%
  summarise(n = n(), blank_point_id = sum(is.na(non_idp_point_id)))
```

You'll see `blank_point_id == n` for `NG037` and `0` for every other
state.
