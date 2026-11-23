"""Deterministic parser for the online income-return summary (déclaration 2042).

impots.gouv prints one box per line: "1AJ Salaires - Déclarant 1 : 45000".
No model is involved: the boxes are read as printed, then mapped to foyer
fields. Boxes without a mapping are listed so nothing is silently dropped.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from decimal import Decimal

from .fields import numbers

_BOX = re.compile(r"^\s*(\d[A-Z]{2})\s+(.+?)\s*:\s*(-?[\d   .]+(?:,\d+)?)\s*(?:€)?\s*$")


@dataclass(frozen=True)
class Box:
    code: str
    label: str
    amount: Decimal
    line: int


def parse_boxes(text: str) -> dict[str, Box]:
    """First occurrence of each box code (the summary repeats some of them)."""
    out: dict[str, Box] = {}
    for i, ln in enumerate(text.splitlines(), 1):
        m = _BOX.match(ln)
        if not m or m.group(1) in out:
            continue
        nums = numbers(m.group(3))
        if len(nums) != 1:
            continue
        out[m.group(1)] = Box(m.group(1), m.group(2), nums.pop(), i)
    return out


# box -> (path in the foyer dict, declarant index or None)
_DECL = {
    "1AJ": ("salaires", 0), "1BJ": ("salaires", 1),
    "1AK": ("frais_reels", 0), "1BK": ("frais_reels", 1),
    "1AS": ("pensions", 0), "1BS": ("pensions", 1),
    "1GH": ("heures_sup_exonerees", 0), "1HH": ("heures_sup_exonerees", 1),
    "6NS": ("per_versements", 0), "6NT": ("per_versements", 1),
}
_CAPITAUX = {"2DC": "dividendes", "2TR": "interets", "3VG": "plus_values", "3SG": "abattement_duree_detention",
             "2CK": "prelevement_forfaitaire_acquitte"}
_CHARGES = {"6GU": "pensions_autres", "6DE": "csg_deductible"}
_PAS = ("8HV", "8IV")
_SCOLARITE = {"7EA": "college", "7EC": "lycee", "7EF": "superieur"}
# Informational boxes that change nothing in the engine as modelled.
_INFO = {"2BH": "CSG-deductible base of RCM: only matters under the barème option (2OP)"}


def foyer_draft(boxes: dict[str, Box], annee_revenus: int) -> tuple[dict, list[str]]:
    """Build a foyer dict from the boxes; return it with the list of unmapped boxes.

    Fields the declaration summary does not carry (situation, birth dates,
    dependants, PER plafonds from the previous avis) are left as TODO markers.
    """
    couple = any(c in boxes for c in ("1BJ", "1BS", "6NT", "1HH", "1BK"))
    decls: list[dict] = [{"naissance": "TODO"} for _ in range(2 if couple else 1)]
    foyer: dict = {"annee_revenus": annee_revenus, "situation": "TODO (marie/pacse)" if couple else "TODO",
                   "declarants": decls, "personnes_a_charge": "TODO"}
    capitaux: dict = {}
    charges: dict = {}
    avantages: list[dict] = []
    scol: dict = {}
    pas = Decimal(0)
    unmapped: list[str] = []
    for code, b in boxes.items():
        if code in _DECL:
            field, idx = _DECL[code]
            decls[idx][field] = b.amount
        elif code in _CAPITAUX:
            capitaux[_CAPITAUX[code]] = b.amount
        elif code in _CHARGES:
            charges[_CHARGES[code]] = b.amount
        elif code in _SCOLARITE:
            scol[_SCOLARITE[code]] = int(b.amount)
        elif code in _PAS:
            pas += b.amount
        elif code == "4BE":
            foyer["fonciers"] = {"regime": "micro", "recettes": b.amount}
        elif code == "7UF":
            avantages.append({"dispositif": "dons", "interet_general": b.amount})
        elif code == "7DB":
            avantages.append({"dispositif": "emploi_domicile", "depenses": b.amount})
        elif code in _INFO:
            continue
        else:
            unmapped.append(f"{code} {b.label} (line {b.line})")
    for d in decls:
        if d.get("per_versements"):
            d["per_plafond_disponible"] = "TODO (plafond printed on the previous year's avis)"
    if capitaux:
        foyer["capitaux"] = capitaux
    if charges:
        foyer["charges"] = charges
    if scol:
        avantages.append({"dispositif": "scolarite", **scol})
    if avantages:
        foyer["avantages"] = avantages
    if pas:
        foyer["prelevements"] = {"pas_preleve": pas}
    return foyer, unmapped
