"""Typed schema of a tax year's rule file (rules/ir/revenus-YYYY.yaml).

Every section carries its legal source and a verification status, so a value
that was never checked against a primary text is visible as such.
"""

from __future__ import annotations

from decimal import Decimal
from enum import StrEnum
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .money import Money, Rate, load_yaml

RULES_DIR = Path(__file__).resolve().parents[2] / "rules" / "ir"


class Status(StrEnum):
    VERIFIED = "verified"  # read in the primary text (CGI, BOFiP, LF/LFSS)
    PRESS = "press"  # only found in secondary sources
    UNVERIFIED = "unverified"  # placeholder: must not be trusted


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class Section(Strict):
    source: str
    status: Status


class Tranche(Strict):
    seuil: Money  # lower bound of the bracket, on the per-part income
    taux: Rate


class Bareme(Section):
    tranches: list[Tranche]

    @model_validator(mode="after")
    def _sorted(self) -> Bareme:
        seuils = [t.seuil for t in self.tranches]
        if seuils != sorted(seuils) or seuils[0] != 0:
            raise ValueError("tranches must start at 0 and be sorted")
        return self


class QuotientFamilial(Section):
    plafond_demi_part: Money
    plafond_parent_isole: Money  # the two half-parts of the first child, case T
    plafond_case_l: Money  # the half-part of case L (single who raised a child)


class Decote(Section):
    forfait_seul: Money
    forfait_couple: Money
    taux: Rate


class AbattementSalaires(Section):
    taux: Rate
    minimum: Money
    maximum: Money


class AbattementPensions(Section):
    taux: Rate
    minimum_par_personne: Money
    maximum_foyer: Money


class AbattementAge(Section):
    """CGI 157 bis: declarants aged 65+ or invalid."""

    seuil_1: Money
    montant_1: Money
    seuil_2: Money
    montant_2: Money
    age: int = 65


class Charges(Section):
    plafond_pension_enfant_majeur: Money


class Capitaux(Section):
    pfu_taux_ir: Rate
    abattement_dividendes: Rate  # under the barème option


class MicroActivite(Strict):
    seuil: Money
    abattement: Rate


class Micro(Section):
    abattement_minimum: Money
    foncier: MicroActivite
    bic: dict[str, MicroActivite]
    bnc: MicroActivite


class DeficitFoncier(Section):
    plafond_global: Money
    plafond_renovation_energetique: Money


class PrelevementsSociaux(Section):
    taux: dict[str, Rate]  # by income nature: fonciers, plus_values, bic_non_pro, ...
    csg_deductible: dict[str, Rate]


class TrancheContribution(Strict):
    seuil: Money
    taux: Rate


class CEHR(Section):
    seul: list[TrancheContribution]
    couple: list[TrancheContribution]


class CDHR(Section):
    applicable: bool
    taux_minimum: Rate | None = None
    seuil_seul: Money | None = None
    seuil_couple: Money | None = None


class Bucket(StrEnum):
    HORS_PLAFOND = "hors_plafond"
    GLOBAL = "global"  # plafond général (10 000)
    MAJORE = "majore"  # outre-mer / SOFICA (18 000)


class Dispositif(Strict):
    nature: Literal["reduction", "credit"]
    bucket: Bucket
    quote_part_plafond: Rate = Decimal(1)  # Girardin: fraction counted in the cap
    ordre: int  # imputation order for réductions
    case: str
    source: str
    status: Status
    taux: Rate | None = None
    plafond: Money | None = None
    plafond_couple: Money | None = None
    params: dict[str, Decimal] = Field(default_factory=dict)


class Niches(Section):
    plafond_global: Money
    plafond_majore: Money


class Recouvrement(Section):
    seuil_mise_en_recouvrement: Money
    seuil_restitution: Money


class RuleSet(Strict):
    annee_revenus: int
    loi_de_finances: str
    bareme: Bareme
    quotient_familial: QuotientFamilial
    decote: Decote
    abattement_salaires: AbattementSalaires
    abattement_pensions: AbattementPensions
    abattement_age: AbattementAge
    charges: Charges
    capitaux: Capitaux
    micro: Micro
    deficit_foncier: DeficitFoncier
    prelevements_sociaux: PrelevementsSociaux
    cehr: CEHR
    cdhr: CDHR
    niches: Niches
    dispositifs: dict[str, Dispositif]
    recouvrement: Recouvrement

    def unverified(self) -> list[str]:
        out = [n for n, s in self if isinstance(s, Section) and s.status != Status.VERIFIED]
        out += [f"dispositifs.{k}" for k, d in self.dispositifs.items() if d.status != Status.VERIFIED]
        return out


def load_rules(annee_revenus: int, rules_dir: Path = RULES_DIR) -> RuleSet:
    path = rules_dir / f"revenus-{annee_revenus}.yaml"
    if not path.exists():
        raise FileNotFoundError(f"no rule file for income year {annee_revenus}: {path}")
    rs = RuleSet.model_validate(load_yaml(path))
    if rs.annee_revenus != annee_revenus:
        raise ValueError(f"{path} declares annee_revenus={rs.annee_revenus}")
    return rs
