# ==============================================================================
# Repair helper for the 2026-08-30 partner data_recovery_workbook batch
# (2_monitoring/reports/partner_data_recovery/outputs/<Partner>/) - every one of the
# 19 outgoing copies has the same corruption: each worksheet's _rels
# references a xl/drawings/drawingN.xml that doesn't actually exist in the
# archive (an openpyxl DataValidation-extension artifact, not partner
# damage - confirmed present in the OUTGOING FACT copy before any partner
# ever touched it, 2026-09-01). openpyxl's default loader raises KeyError
# on this ("no item named 'xl/drawings/drawing1.xml'"), so returned
# (partner-filled) copies need the same repair before they can be read at
# all - same family of issue as prep_real_submissions.R's read_excel_robust()
# and prep_accessibility_layer.R's own xlsx workaround, different specific
# corruption.
#
# Fix: strip the dangling <Relationship .../> from each sheetN.xml.rels and
# the matching <drawing r:id="..."/> element from sheetN.xml, in a copy -
# never mutates the original file.
# ==============================================================================
import os
import re
import shutil
import tempfile
import zipfile

import openpyxl


def load_repaired_workbook(path, data_only=True):
    """Returns (openpyxl.Workbook, was_repaired: bool). Read-only use -
    never writes back to `path` itself."""
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        drawing_files = {n for n in names if n.startswith("xl/drawings/") and n.endswith(".xml")}
        missing_target_rels = set()
        for n in names:
            if n.startswith("xl/worksheets/_rels/") and n.endswith(".rels"):
                content = z.read(n).decode("utf-8")
                for m in re.finditer(r'Target="\.\./drawings/([^"]+)"', content):
                    if f"xl/drawings/{m.group(1)}" not in drawing_files:
                        missing_target_rels.add(n)
        if not missing_target_rels:
            return openpyxl.load_workbook(path, data_only=data_only), False

        tmp_dir = tempfile.mkdtemp(prefix="xlsx_repair_")
        try:
            repaired_path = os.path.join(tmp_dir, "repaired.xlsx")
            with zipfile.ZipFile(path) as zin, zipfile.ZipFile(repaired_path, "w", zipfile.ZIP_DEFLATED) as zout:
                for item in zin.infolist():
                    data = zin.read(item.filename)
                    if item.filename in missing_target_rels:
                        data = re.sub(
                            rb'<Relationship[^>]*Type="[^"]*relationships/drawing"[^>]*/>', b"", data,
                        )
                    elif item.filename.startswith("xl/worksheets/sheet") and item.filename.endswith(".xml"):
                        data = re.sub(rb"<drawing [^>]*/>", b"", data)
                    zout.writestr(item, data)
            return openpyxl.load_workbook(repaired_path, data_only=data_only), True
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)
