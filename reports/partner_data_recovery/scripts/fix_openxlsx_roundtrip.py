# ==============================================================================
# Fixes a specific openxlsx (R) round-trip bug found 2026-09-03 while
# in-place editing the recovery workbooks: loadWorkbook() -> modify a
# sheet -> saveWorkbook() correctly re-escapes XML entities for anything
# openxlsx itself WRITES fresh, but does NOT re-escape a literal "&"
# already present in an EXISTING sheet name it's just carrying through
# unchanged - "GPS Duplicates & Distant Pts" (present in every one of
# these workbooks) comes out as a raw, unescaped "&" in xl/workbook.xml,
# which is invalid XML and makes the file fail to open in Excel or
# openpyxl at all ("not well-formed (invalid token)").
#
# This is a DIFFERENT issue from xlsx_repair.py's dangling-drawing-
# reference fix (that one's read-time only, for files nobody's writing to
# again; this one has to fix the file ON DISK, since a partner will open
# it directly in Excel, not through our own load_repaired_workbook()).
#
# Usage: python fix_openxlsx_roundtrip.py <path.xlsx> [<path2.xlsx> ...]
# Fixes each file in place. Safe to run on an already-fixed file (only
# touches a literal "&" not already part of a valid XML entity).
# ==============================================================================
import re
import sys
import zipfile
import shutil
import tempfile
import os

# Matches a literal "&" NOT already followed by a known entity pattern
# (amp;, lt;, gt;, apos;, quot;, or a numeric #NNN;/#xHHH; reference).
UNESCAPED_AMP_RE = re.compile(r"&(?!amp;|lt;|gt;|apos;|quot;|#\d+;|#x[0-9a-fA-F]+;)")


def fix_file(path):
    with zipfile.ZipFile(path, "r") as zin:
        names = zin.namelist()
        if "xl/workbook.xml" not in names:
            print(f"  {path}: no xl/workbook.xml found, skipping")
            return False
        contents = {n: zin.read(n) for n in names}

    workbook_xml = contents["xl/workbook.xml"].decode("utf-8")
    fixed_xml, n_subs = UNESCAPED_AMP_RE.subn("&amp;", workbook_xml)
    if n_subs == 0:
        print(f"  {path}: no unescaped ampersands found, nothing to fix")
        return False

    contents["xl/workbook.xml"] = fixed_xml.encode("utf-8")

    fd, tmp_path = tempfile.mkstemp(suffix=".xlsx", dir=os.path.dirname(os.path.abspath(path)))
    os.close(fd)
    try:
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as zout:
            for name in names:
                zout.writestr(name, contents[name])
        shutil.move(tmp_path, path)
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise

    print(f"  {path}: fixed {n_subs} unescaped ampersand(s)")
    return True


def main():
    if len(sys.argv) < 2:
        print("Usage: python fix_openxlsx_roundtrip.py <path.xlsx> [<path2.xlsx> ...]")
        sys.exit(1)
    for path in sys.argv[1:]:
        fix_file(path)


if __name__ == "__main__":
    main()
