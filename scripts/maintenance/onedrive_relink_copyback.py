"""Re-link copy-back for a SharePoint folder that lost its OneDrive sync (written 4 Oct 2026 for "IMPACT NGA - 02. MSNA").

On 4 Oct 2026 the folder C:\\Users\\JackPHILPOTT\\ACTED\\IMPACT NGA - 02. MSNA stopped being a OneDrive sync root (after ~15:00).
Work done afterwards exists only on this laptop. This script brings it back into a freshly synced copy so OneDrive
uploads it, without ever deleting anything and without overwriting anything SharePoint changed in the meantime.

TIMING: re-link only AFTER the night's accessibility chain (step 3) and any draws/merge.
  Five assert_fresh(mode="stop") checks compare file ORDER (artifact mtime >= newest source mtime): the pools, the GIS
  layer, the site-frame .rds and staged batches vs master_accessibility_status_ward_level.csv.
  Files rewritten after --since are copied back with exact mtimes (shutil.copy2), so their order holds. Unchanged files
  keep SharePoint's whole-second times, which could, rarely, flip a pair written within the same second.

PROCEDURE (all sessions idle):
  0. OneDrive settings -> Account -> "Stop sync" on "IMPACT NGA - MSNA N-WEC 2026". It was created 4 Oct 22:26 by a Sync
     click on the workspace folder and overlaps 02. MSNA. NEVER DELETE a folder while it is still a sync: that deletes the
     SharePoint content. Only after "Stop sync" is it a plain local copy.
  1. Close VS Code and every R / Python / Claude session working in the folder.
  2. Rename the old folder, e.g. to "IMPACT NGA - 02. MSNA (local 2026-10-04)".
  3. SharePoint (browser) -> IMPACT NGA site -> Documents -> "02. MSNA" -> Sync. OneDrive recreates
     "IMPACT NGA - 02. MSNA" with on-demand files. Wait until the OneDrive icon says "Up to date".
  4. Dry run (changes nothing; writes the plan into OLD\\_relink_reports\\):
       python onedrive_relink_copyback.py --old "<renamed folder>" --new "<fresh folder>" --since "2026-10-04 12:00"
  5. Read the summary. Every FLAG row needs a human decision first.
  6. Execute: the same command plus --execute. Copies are md5-verified (old vs new) at the end.
  7. Wait for OneDrive to upload, then re-run the validity suite and the conflict-copy scan.
  8. Leftovers in C:\\Users\\JackPHILPOTT\\ACTED: "IMPACT NGA - output", "IMPACT NGA - output (1)", "IMPACT NGA - MSNA N-WEC 2026"
     and the renamed old folder. They are unlinked copies: confirm in OneDrive settings that none is listed as a synced
     folder, and keep the renamed old folder until the copy-back is verified. Only then remove them, by hand.
  Tested 4 Oct 2026 on a synthetic pair: every classification, the FLAG stop, --execute with md5 verify, the archive
  move, a >260-character path and the "still enumerating" guard all pass.

CLASSIFICATION, per relative file path:
  OLD = the renamed local folder; NEW = the fresh synced folder.
  - skip_stub: OLD holds a cloud-only placeholder, never downloaded, so SharePoint already has the content.
  - skip_cache: __pycache__ / *.pyc (regenerated automatically).
  - In both OLD (a real file) and NEW:
      identical       same size and modified times within 2 s;
      FLAG_remote_newer   NEW (SharePoint) modified later than OLD: never overwritten;
      FLAG_same_time_diff_size   same time but different size;
      copy_overwrite  OLD is newer.
  - Only in OLD: copy_new.
  - Only in NEW: archive_removed_locally if NEW's modified time is before --since (it was removed or moved here after the
    break); otherwise FLAG_remote_added (someone added it on SharePoint after the break; kept).
--execute performs only the copy_* and archive_* actions. archive_* moves files to NEW\\_relink_archived_<date>\\<same path>.
Nothing is ever deleted.
"""
import argparse, csv, datetime, hashlib, os, shutil, stat, sys

STUB_BITS = 0x400000 | 0x1000   # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS | FILE_ATTRIBUTE_OFFLINE
TOL = 2.0


def lp(p):
    """Extended-length path so very deep partner-package paths (> 260 chars) work."""
    p = os.path.abspath(p)
    return p if p.startswith("\\\\?\\") else "\\\\?\\" + p


def excluded(rel, prefixes):
    r = rel.replace("/", "\\").lower()
    return any(r == p or r.startswith(p + "\\") for p in prefixes)


def walk(root, prefixes=()):
    out = {}
    for dirpath, dirnames, filenames in os.walk(lp(root)):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, lp(root))
            if excluded(rel, prefixes):
                continue
            try:
                st = os.stat(full)   # metadata only: never hydrates a placeholder
            except OSError as e:
                out[rel] = {"error": str(e)}
                continue
            out[rel] = {"size": st.st_size, "mtime": st.st_mtime,
                        "stub": bool(getattr(st, "st_file_attributes", 0) & STUB_BITS)}
    return out


def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def is_cache(rel):
    parts = rel.replace("/", "\\").split("\\")
    return "__pycache__" in parts or rel.lower().endswith(".pyc")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True)
    ap.add_argument("--new", required=True)
    ap.add_argument("--since", required=True, help='start of the possible break window, e.g. "2026-10-04 12:00"')
    ap.add_argument("--execute", action="store_true")
    ap.add_argument("--exclude", action="append", default=[],
                    help="relative folder to leave out on both sides (repeatable), e.g. a subtree synced separately")
    ap.add_argument("--keep-remote-newer", action="store_true",
                    help="where SharePoint's copy is newer, keep it (no action, listed as kept_remote_newer); "
                         "the local version stays in the renamed old folder")
    a = ap.parse_args()
    prefixes = [p.replace("/", "\\").strip("\\").lower() for p in a.exclude]
    since = datetime.datetime.strptime(a.since, "%Y-%m-%d %H:%M").timestamp()
    for p in (a.old, a.new):
        if not os.path.isdir(lp(p)):
            sys.exit("not a folder: " + p)
    if os.path.normcase(os.path.abspath(a.old)) == os.path.normcase(os.path.abspath(a.new)):
        sys.exit("--old and --new are the same folder")
    print("walking OLD ...", flush=True)
    old = walk(a.old, prefixes)
    print("walking NEW ...", flush=True)
    new = walk(a.new, prefixes)
    if prefixes:
        print("excluded on both sides:", ", ".join(a.exclude))
    # guard: NEW must be fully enumerated. Every pre-break OLD file should exist in NEW (as a placeholder at least).
    pre = [r for r, m in old.items() if "error" not in m and m["mtime"] < since and not is_cache(r)]
    missing_pre = [r for r in pre if r not in new]
    if pre and len(missing_pre) > 0.02 * len(pre):
        sys.exit("STOP: %d of %d files that existed before the break are missing from NEW. Is OneDrive still enumerating? "
                 "Wait for 'Up to date' and re-run." % (len(missing_pre), len(pre)))

    rows = []
    for rel in sorted(set(old) | set(new)):
        o, n = old.get(rel), new.get(rel)
        if (o and "error" in o) or (n and "error" in n):
            act = "FLAG_stat_error"
        elif o and is_cache(rel):
            act = "skip_cache"
        elif o and o["stub"]:
            act = "skip_stub" if n else "FLAG_stub_missing_remote"
        elif o and n:
            if o["size"] == n["size"] and abs(o["mtime"] - n["mtime"]) <= TOL:
                act = "identical"
            elif n["mtime"] > o["mtime"] + TOL:
                act = "kept_remote_newer" if a.keep_remote_newer else "FLAG_remote_newer"
            elif abs(o["mtime"] - n["mtime"]) <= TOL:
                act = "FLAG_same_time_diff_size"
            else:
                act = "copy_overwrite"
        elif o:
            act = "copy_new"
        else:
            act = "archive_removed_locally" if n["mtime"] < since else "FLAG_remote_added"
        rows.append({"action": act, "path": rel,
                     "old_size": o.get("size") if o else "", "old_mtime": fmt(o.get("mtime")) if o else "",
                     "new_size": n.get("size") if n else "", "new_mtime": fmt(n.get("mtime")) if n else ""})

    if not rows:
        print("Nothing to compare: both folders are empty after exclusions. Nothing changed.")
        return
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M")
    rep_dir = os.path.join(lp(a.old), "_relink_reports")
    os.makedirs(rep_dir, exist_ok=True)
    plan = os.path.join(rep_dir, "relink_plan_%s.csv" % stamp)
    with open(plan, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    counts = {}
    for r in rows:
        counts[r["action"]] = counts.get(r["action"], 0) + 1
    to_copy = [r for r in rows if r["action"].startswith("copy_")]
    print("PLAN %s" % plan.replace("\\\\?\\", ""))
    for k in sorted(counts):
        print("  %-28s %8d" % (k, counts[k]))
    print("  bytes to copy: %.1f MB" % (sum(int(r["old_size"]) for r in to_copy) / 1e6))
    flags = [r for r in rows if r["action"].startswith("FLAG_")]
    if flags:
        print("FLAGS (decide before --execute):")
        for r in flags[:40]:
            print("   ", r["action"], r["path"], "| old", r["old_mtime"], r["old_size"], "| new", r["new_mtime"], r["new_size"])
    if not a.execute:
        print("DRY RUN: nothing changed. Re-run with --execute once the flags are understood.")
        return
    if flags:
        sys.exit("STOP: %d FLAG rows; resolve them first (nothing changed)." % len(flags))
    arch_root = os.path.join(lp(a.new), "_relink_archived_%s" % datetime.date.today().isoformat())
    done = []
    for r in rows:
        src, dst = os.path.join(lp(a.old), r["path"]), os.path.join(lp(a.new), r["path"])
        if r["action"].startswith("copy_"):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.exists(dst):
                os.chmod(dst, stat.S_IWRITE)
            shutil.copy2(src, dst)
            done.append(r)
        elif r["action"] == "archive_removed_locally":
            tgt = os.path.join(arch_root, r["path"])
            os.makedirs(os.path.dirname(tgt), exist_ok=True)
            shutil.move(dst, tgt)
    bad = [r["path"] for r in done if md5(os.path.join(lp(a.old), r["path"])) != md5(os.path.join(lp(a.new), r["path"]))]
    print("copied %d files; md5 mismatches: %d %s" % (len(done), len(bad), bad[:10]))
    print("archived %d files into %s" % (counts.get("archive_removed_locally", 0), arch_root.replace("\\\\?\\", "")))
    if bad:
        sys.exit(1)


def fmt(t):
    return "" if t in (None, "") else datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S")


if __name__ == "__main__":
    main()
