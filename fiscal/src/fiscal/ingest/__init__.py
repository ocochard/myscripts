"""Turn source documents (PDF) into reviewable text and typed extracts.

Pipeline: PDF -> layout-preserving text (pdftotext, pdfplumber fallback)
-> document type -> type-specific parser -> extract with provenance.
Extracts are proposals: a human reviews them before they reach a foyer file.
"""

from .extract import DocType, Document, classify, extract_text, ingest

__all__ = ["DocType", "Document", "classify", "extract_text", "ingest"]
