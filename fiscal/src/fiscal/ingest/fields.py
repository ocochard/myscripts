"""Fields to extract per document type, and the deterministic check of each proposal."""

from __future__ import annotations

import re
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation

from .extract import DocType


@dataclass(frozen=True)
class FieldSpec:
    key: str
    description: str  # French, shown to the model
    case: str | None = None  # 2042 box the value feeds, when there is one
    entier: bool = False


SPECS: dict[DocType, list[FieldSpec]] = {
    DocType.AVIS_IR: [
        FieldSpec("annee_revenus", "année des revenus imposés (ex. 2025 pour l'avis 2026)", entier=True),
        FieldSpec("nombre_parts", "nombre de parts du quotient familial"),
        FieldSpec("revenu_fiscal_reference", "revenu fiscal de référence", entier=True),
        FieldSpec("revenu_brut_global", "revenu brut global", entier=True),
        FieldSpec("revenu_imposable", "revenu net imposable / revenu imposable", entier=True),
        FieldSpec("impot_net", "impôt sur le revenu net (avant prélèvement à la source)", entier=True),
        FieldSpec("prelevements_sociaux", "total des prélèvements sociaux", entier=True),
        FieldSpec("salaires_declarant1", "traitements et salaires du déclarant 1", "1AJ", entier=True),
        FieldSpec("salaires_declarant2", "traitements et salaires du déclarant 2", "1BJ", entier=True),
        FieldSpec("per_plafond_declarant1",
                  "plafond de déduction épargne retraite (PER) disponible pour le déclarant 1, total", entier=True),
        FieldSpec("per_plafond_declarant2",
                  "plafond de déduction épargne retraite (PER) disponible pour le déclarant 2, total", entier=True),
    ],
    DocType.AVIS_SITUATION: [
        FieldSpec("annee_revenus", "année des revenus déclarés", entier=True),
        FieldSpec("nombre_parts", "nombre de parts du quotient familial"),
        FieldSpec("revenu_fiscal_reference", "revenu fiscal de référence", entier=True),
        FieldSpec("revenu_imposable", "revenu net imposable / revenu imposable", entier=True),
        FieldSpec("impot_net", "impôt sur le revenu net", entier=True),
    ],
    DocType.IFU: [
        FieldSpec("annee_revenus", "année des revenus", entier=True),
        FieldSpec("dividendes", "revenus distribués éligibles à l'abattement de 40 %", "2DC"),
        FieldSpec("interets", "produits de placement à revenu fixe / intérêts", "2TR"),
        FieldSpec("plus_values", "plus-values de cession de valeurs mobilières", "3VG"),
        FieldSpec("moins_values", "moins-values de cession", "3VH"),
        FieldSpec("credit_prelevement_forfaitaire",
                  "prélèvement forfaitaire non libératoire déjà versé (crédit d'impôt)", "2CK"),
        FieldSpec("csg_deductible_base", "revenus ouvrant droit à CSG déductible", "2BH"),
    ],
    DocType.BULLETIN_PAIE: [
        FieldSpec("annee", "année de la période de paie", entier=True),
        FieldSpec("mois", "mois de la période de paie (1-12)", entier=True),
        FieldSpec("net_imposable_mois", "net imposable du mois"),
        FieldSpec("net_imposable_cumul", "cumul annuel du net imposable (depuis janvier)"),
        FieldSpec("pas_mois", "impôt sur le revenu prélevé à la source ce mois"),
        FieldSpec("pas_cumul", "cumul annuel du prélèvement à la source"),
    ],
    DocType.RELEVE_PER: [
        FieldSpec("annee", "année concernée par le relevé", entier=True),
        FieldSpec("versements_volontaires_deductibles",
                  "versements volontaires de l'année (déductibles du revenu)", "6NS"),
        FieldSpec("valeur_contrat", "valeur / épargne totale du contrat à la date du relevé"),
    ],
}

# French printed numbers: "52 314", "52 314,00", "1.234,56", "0,5", "2,5", "2025".
_NUM = re.compile(r"(?<![\d,.])-?\d{1,3}(?:[   .]\d{3})+(?:,\d+)?(?![\d])|(?<![\d,.])-?\d+(?:,\d+)?(?![\d])")


def numbers(line: str) -> set[Decimal]:
    """Numbers printed on a line, as absolute values (payslips print deductions as negatives)."""
    out: set[Decimal] = set()
    for m in _NUM.finditer(line):
        raw = re.sub(r"[   .]", "", m.group()).replace(",", ".")
        try:
            out.add(abs(Decimal(raw)))
        except InvalidOperation:
            continue
    return out


def verify(value: Decimal, ligne: int | None, lines: list[str]) -> tuple[str, int | None]:
    """Return (status, line) for a proposed value.

    verifie: the number is printed on the cited line;
    autre_ligne: printed exactly once elsewhere (the cited line was wrong);
    introuvable: not printed anywhere, or ambiguous - treat as a hallucination.
    """
    if ligne is not None and 1 <= ligne <= len(lines) and value in numbers(lines[ligne - 1]):
        return "verifie", ligne
    hits = [i for i, ln in enumerate(lines, 1) if value in numbers(ln)]
    if len(hits) == 1:
        return "autre_ligne", hits[0]
    return "introuvable", None
