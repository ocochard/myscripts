"""Input model of a household (foyer fiscal) for one income year.

Field comments give the 2042 box each value comes from, so every input can be
checked against a filed return or an avis d'imposition. Anything the engine
does not model is rejected by the schema (extra="forbid") rather than ignored.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal
from enum import StrEnum
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .money import Money


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class Situation(StrEnum):
    CELIBATAIRE = "celibataire"
    MARIE = "marie"
    PACSE = "pacse"
    DIVORCE = "divorce"
    VEUF = "veuf"


class PersonneACharge(Strict):
    naissance: date
    garde_alternee: bool = False
    invalide: bool = False  # carte mobilité inclusion "invalidité"
    per_versements: Money = Decimal(0)  # 6NU: PER held by a rattached dependant
    per_plafond_disponible: Money | None = None  # 6PU; minimum 10 % PASS when no earned income


class RecettesMicroBIC(Strict):
    nature: str  # key of rules.micro.bic (vente, services, meuble_classe, ...)
    recettes: Money


class Declarant(Strict):
    naissance: date
    invalide: bool = False  # case P
    ancien_combattant: bool = False  # case W
    salaires: Money = Decimal(0)  # 1AJ
    frais_reels: Money | None = None  # 1AK; None => abattement 10 %
    heures_sup_exonerees: Money = Decimal(0)  # 1GH/1HH: exempt, but part of the RFR
    pensions: Money = Decimal(0)  # 1AS
    bic_micro: list[RecettesMicroBIC] = Field(default_factory=list)  # 5KO/5KP/5ND/5NG...
    bic_non_pro_reel: Money = Decimal(0)  # 5NA (LMNP réel, positive result)
    bnc_micro: Money = Decimal(0)  # 5HQ / 5KU
    per_versements: Money = Decimal(0)  # 6NS
    per_plafond_disponible: Money | None = None  # from the avis N-1


class Capitaux(Strict):
    dividendes: Money = Decimal(0)  # 2DC
    interets: Money = Decimal(0)  # 2TR
    plus_values: Money = Decimal(0)  # 3VG, net of losses (2074)
    abattement_duree_detention: Money = Decimal(0)  # 3SG, barème option only
    option_bareme: bool = False  # 2OP: global, all RCM and PV of the year
    prelevement_forfaitaire_acquitte: Money = Decimal(0)  # 2CK, credit
    ps_deja_preleves_rcm: bool = True  # French paying agent withheld PS on 2DC/2TR


class FonciersMicro(Strict):
    regime: Literal["micro"] = "micro"
    recettes: Money  # 4BE


class FonciersReel(Strict):
    regime: Literal["reel"] = "reel"
    resultat: Money = Decimal(0)  # 4BA
    deficit_imputable_fonciers: Money = Decimal(0)  # 4BB
    deficit_imputable_global: Money = Decimal(0)  # 4BC
    deficits_anterieurs: Money = Decimal(0)  # 4BD
    renovation_energetique: bool = False  # doubled 4BC cap


Fonciers = Annotated[FonciersMicro | FonciersReel, Field(discriminator="regime")]


class ChargesDeductibles(Strict):
    pensions_enfants_majeurs: list[Money] = Field(default_factory=list)  # 6EL/6EM, one per child
    pensions_autres: Money = Decimal(0)  # 6GU
    csg_deductible: Money = Decimal(0)  # 6DE (CSG on N-1 capital income)
    deficits_globaux_anterieurs: Money = Decimal(0)  # 6FA..6FL


# Réductions / crédits: one typed entry per dispositif.

class ReportDon(Strict):
    annee: int  # income year the excess was generated
    montant: Money


class Dons(Strict):
    dispositif: Literal["dons"] = "dons"
    aide_personnes: Money = Decimal(0)  # 7UD (75 % up to the Coluche cap)
    aide_personnes_plafond_majore: Money = Decimal(0)  # 7VM: 2025 gifts from 14.10 (raised cap)
    interet_general: Money = Decimal(0)  # 7UF (66 %, 20 % of RNI)
    reports: list[ReportDon] = Field(default_factory=list)  # 7XS..7XY


class EmploiDomicile(Strict):
    dispositif: Literal["emploi_domicile"] = "emploi_domicile"
    depenses: Money  # 7DB
    majorations: int = 0  # children / dependants / members 65+
    premiere_annee: bool = False  # 7DQ
    invalidite: bool = False  # 7DG


class GardeEnfant(Strict):
    dispositif: Literal["garde_enfant"] = "garde_enfant"
    depenses_par_enfant: list[Money]  # 7GA..7GC, children under 6


class Scolarite(Strict):
    dispositif: Literal["scolarite"] = "scolarite"
    college: int = 0  # 7EA
    lycee: int = 0  # 7EC
    superieur: int = 0  # 7EF


class Souscription(Strict):
    dispositif: Literal["pme_ir", "fcpi", "fip", "fip_corse_outremer", "sofica"]
    montant: Money = Decimal(0)  # at the base rate
    montant_taux_majore: Money = Decimal(0)  # e.g. FCPI paid from 28.9.2025 (25 %); rule param taux_majore


class ReductionDirecte(Strict):
    """Dispositifs whose yearly réduction is computed by the operator (Pinel, Girardin...)."""

    dispositif: Literal["pinel", "denormandie", "girardin_industriel"]
    reduction: Money


Avantage = Annotated[
    Dons | EmploiDomicile | GardeEnfant | Scolarite | Souscription | ReductionDirecte,
    Field(discriminator="dispositif"),
]


class Prelevements(Strict):
    pas_preleve: Money = Decimal(0)  # 8HV..: prélèvement à la source withheld
    acomptes: Money = Decimal(0)  # acomptes contemporains (BIC/BNC/fonciers)
    avance_credits: Money = Decimal(0)  # avance de janvier on réductions/crédits


class FoyerFiscal(Strict):
    annee_revenus: int
    situation: Situation
    declarants: list[Declarant] = Field(min_length=1, max_length=2)
    personnes_a_charge: list[PersonneACharge] = Field(default_factory=list)
    vit_en_couple: bool = False  # single/divorced living in concubinage: no case T / L
    case_l: bool = False  # single, raised a child alone >= 5 years
    per_mutualisation: bool = False  # 6QR: spouses pool their PER plafonds
    capitaux: Capitaux = Capitaux()
    fonciers: Fonciers | None = None
    charges: ChargesDeductibles = ChargesDeductibles()
    avantages: list[Avantage] = Field(default_factory=list)
    prelevements: Prelevements = Prelevements()

    @property
    def couple(self) -> bool:
        return self.situation in (Situation.MARIE, Situation.PACSE)

    @model_validator(mode="after")
    def _coherent(self) -> FoyerFiscal:
        if self.couple != (len(self.declarants) == 2):
            raise ValueError("marie/pacse needs exactly 2 declarants, other situations 1")
        if self.case_l and (self.couple or self.personnes_a_charge or self.vit_en_couple):
            raise ValueError("case L is for a single declarant without dependants")
        kinds = [a.dispositif for a in self.avantages]
        if len(kinds) != len(set(kinds)):
            raise ValueError("each dispositif may appear once")
        return self
