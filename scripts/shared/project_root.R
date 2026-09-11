# ==============================================================================
# Single shared source of truth for 2_monitoring's absolute project root.
#
# ADDED 2026-09-11: generate_review_queue.R and apply_review_decisions.R
# each independently hardcoded this exact same absolute path (and their own
# setwd() call) - if this workspace is ever moved (it already has been
# once, see the parent workspace's own README), every file carrying its own
# copy needs finding and fixing individually rather than one. This file is
# sourced via its own absolute path (unavoidable - a script can't yet know
# its cwd is correct at the point it needs to fix its cwd), but every
# OTHER file that needs the project root now sources this one instead of
# carrying its own copy of the literal path.
#
# Usage: source("c:/Users/.../2_monitoring/scripts/shared/project_root.R")
# at the top of a script, before any relative source()/read path is used.
# ==============================================================================
PROJECT_DIR <- "c:/Users/JackPHILPOTT/ACTED/IMPACT NGA - 02. MSNA/4. Data/MSNA N-WEC 2026/2_monitoring"
setwd(PROJECT_DIR)
