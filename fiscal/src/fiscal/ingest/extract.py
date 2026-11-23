"""PDF text extraction and document classification."""

from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
from enum import StrEnum
from pathlib import Path
from typing import TYPE_CHECKING

import yaml
from pydantic import BaseModel

if TYPE_CHECKING:
    from .llm import Completion

MIN_CHARS_PER_PAGE = 50  # below this the PDF is most likely a scan


class DocType(StrEnum):
    AVIS_IR = "avis_ir"
    AVIS_SITUATION = "avis_situation"  # avis de situation déclarative (issued at filing time)
    DECLARATION_REVENUS = "declaration_revenus"  # online return summary (form n° 2042), one box per line
    TAXE_FONCIERE = "taxe_fonciere"
    BULLETIN_PAIE = "bulletin_paie"
    RELEVE_PER = "releve_per"
    IFU = "ifu"
    INCONNU = "inconnu"


# First match wins; patterns are matched case-insensitively on the full text.
_SIGNATURES: list[tuple[DocType, list[str]]] = [
    (DocType.AVIS_SITUATION, [r"situation\s+d[ée]clarative", r"revenu\s+fiscal\s+de\s+r[ée]f[ée]rence"]),
    (DocType.DECLARATION_REVENUS, [r"\b2042\b", r"^\s*1AJ\s.+:"]),
    (DocType.AVIS_IR, [r"revenu\s+fiscal\s+de\s+r[ée]f[ée]rence", r"imp[oô]t\s+(sur\s+le\s+revenu\s+)?net"]),
    (DocType.TAXE_FONCIERE, [r"taxes?\s+fonci[eè]re"]),
    (DocType.IFU, [r"imprim[ée] fiscal unique|\bIFU\b|2561"]),
    (DocType.RELEVE_PER, [r"plan d.[ée]pargne retraite|\bPER(IN|CO|O)?\b", r"versement|cotisation"]),
    (DocType.BULLETIN_PAIE, [r"bulletin de (paie|salaire)|net [àa] payer", r"brut"]),
]


class Document(BaseModel):
    source: str
    sha256: str
    pages: int
    type: DocType
    text_file: str
    extract_file: str | None = None


def _pages(pdf: Path) -> int:
    import pdfplumber

    with pdfplumber.open(pdf) as doc:
        return len(doc.pages)


def extract_text(pdf: Path) -> str:
    """Layout-preserving text. pdftotext keeps columns aligned, which matters for payslips."""
    if shutil.which("pdftotext"):
        out = subprocess.run(["pdftotext", "-layout", "-enc", "UTF-8", str(pdf), "-"],
                             check=True, capture_output=True, text=True)
        text = out.stdout
    else:
        import pdfplumber

        with pdfplumber.open(pdf) as doc:
            text = "\f".join(p.extract_text(layout=True) or "" for p in doc.pages)
    return text


def classify(text: str) -> DocType:
    for kind, patterns in _SIGNATURES:
        if all(re.search(p, text, re.IGNORECASE | re.MULTILINE) for p in patterns):
            return kind
    return DocType.INCONNU


def _plain(x):
    """Decimals -> int/float-free YAML scalars (exact strings would quote them)."""
    from decimal import Decimal

    if isinstance(x, dict):
        return {k: _plain(v) for k, v in x.items()}
    if isinstance(x, list):
        return [_plain(v) for v in x]
    if isinstance(x, Decimal):
        return int(x) if x == x.to_integral() else str(x)
    return x


def _write_private(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o600)


def ingest(pdf: Path, out_dir: Path, complete: Completion | None = None,
           doc_type: DocType | None = None, modele: str = "llama.cpp") -> Document:
    """Extract text, classify, and when `complete` is given, propose and verify fields."""
    data = pdf.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    text = extract_text(pdf)
    pages = _pages(pdf)
    if len(text.strip()) < MIN_CHARS_PER_PAGE * pages:
        raise ValueError(f"{pdf}: almost no text layer, likely a scan (OCR not wired yet)")
    out_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    stem = f"{pdf.stem}.{sha[:8]}"
    txt = out_dir / f"{stem}.txt"
    _write_private(txt, text)
    doc = Document(source=str(pdf), sha256=sha, pages=pages, type=doc_type or classify(text), text_file=str(txt))
    if doc.type == DocType.DECLARATION_REVENUS:  # read deterministically, no model needed
        from .declaration import foyer_draft, parse_boxes

        boxes = parse_boxes(text)
        m = re.search(r"revenus\s+(20\d\d)", text, re.IGNORECASE)
        draft, unmapped = foyer_draft(boxes, int(m.group(1)) if m else 0)
        body = yaml.safe_dump(_plain(draft), sort_keys=False, allow_unicode=True)
        notes = "".join(f"# NOT MAPPED, handle by hand: {u}\n" for u in unmapped)
        xf = out_dir / f"{stem}.foyer-draft.yaml"
        _write_private(xf, "# Draft built from the return summary: fill every TODO, then review.\n" + notes + body)
        doc = doc.model_copy(update={"extract_file": str(xf)})
    elif complete is not None:
        from .llm import extract_fields

        ex = extract_fields(text, doc.type, complete, modele)
        xf = out_dir / f"{stem}.extract.yaml"
        _write_private(xf, yaml.safe_dump(ex.model_dump(mode="json"), sort_keys=False, allow_unicode=True))
        doc = doc.model_copy(update={"extract_file": str(xf)})
    _write_private(out_dir / f"{stem}.meta.yaml",
                   yaml.safe_dump(doc.model_dump(mode="json"), sort_keys=False))
    return doc
