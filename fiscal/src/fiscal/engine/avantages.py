"""Réductions and crédits d'impôt: theoretical amounts, imputation, global niche cap."""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal

from ..foyer import (
    Dons, EmploiDomicile, FoyerFiscal, GardeEnfant, ReductionDirecte, Scolarite,
    ReportDon, Souscription,
)
from ..money import ZERO, clamp0, euro_round
from ..rules import Bucket, Dispositif, RuleSet
from .trace import Trace, UnsupportedCase

DONS_REPORT_YEARS = 5  # CGI 200-1, 4e alinéa


@dataclass(frozen=True)
class AvantageCalcule:
    key: str
    rule: Dispositif
    montant: Decimal  # theoretical réduction / crédit
    notes: dict[str, Decimal] = field(default_factory=dict)


def _param(d: Dispositif, key: str, name: str) -> Decimal:
    if name not in d.params:
        raise UnsupportedCase(f"rule dispositifs.{key}.params.{name} missing")
    return d.params[name]


def _dons(a: Dons, rni: Decimal, d: Dispositif, annee: int) -> tuple[Decimal, list[ReportDon], dict]:
    # A gift in the window with a raised cap (7VM) lifts the cap for all the year's 75 % gifts.
    if a.aide_personnes_plafond_majore:
        plafond_75 = _param(d, "dons", "plafond_75_majore")
    else:
        plafond_75 = _param(d, "dons", "plafond_75")
    total75 = a.aide_personnes + a.aide_personnes_plafond_majore
    base75 = min(total75, plafond_75)
    overflow = total75 - base75
    cap = rni * _param(d, "dons", "plafond_pct_rni")
    live = sorted((rp for rp in a.reports if annee - rp.annee <= DONS_REPORT_YEARS), key=lambda x: x.annee)
    # Prior-year excess is consumed first, oldest first (BOI-IR-RICI-250-30).
    remaining = cap
    reports_out: list[ReportDon] = []
    base66 = ZERO
    for rp in live:
        used = min(rp.montant, remaining)
        base66 += used
        remaining -= used
        if rp.montant > used and annee + 1 - rp.annee <= DONS_REPORT_YEARS:
            reports_out.append(ReportDon(annee=rp.annee, montant=rp.montant - used))
    current = a.interet_general + overflow
    used = min(current, remaining)
    base66 += used
    if current > used:
        reports_out.append(ReportDon(annee=annee, montant=current - used))
    montant = base75 * _param(d, "dons", "taux_75") + base66 * _param(d, "dons", "taux_66")
    return montant, reports_out, {"base_75": base75, "base_66": base66, "plafond_20pct": cap}


def _emploi_domicile(a: EmploiDomicile, d: Dispositif) -> Decimal:
    p = lambda n: _param(d, "emploi_domicile", n)  # noqa: E731
    if a.invalidite:
        plafond = p("plafond_invalidite")
    elif a.premiere_annee:
        plafond = min(p("plafond_premiere_annee") + a.majorations * p("majoration"), p("plafond_max_premiere_annee"))
    else:
        plafond = min(p("plafond_base") + a.majorations * p("majoration"), p("plafond_max"))
    assert d.taux is not None
    return min(a.depenses, plafond) * d.taux


def theoriques(f: FoyerFiscal, rni: Decimal, rng: Decimal, r: RuleSet, t: Trace) -> tuple[list[AvantageCalcule], list[ReportDon]]:
    out: list[AvantageCalcule] = []
    reports: list[ReportDon] = []
    for a in f.avantages:
        key = a.dispositif
        if key not in r.dispositifs:
            raise UnsupportedCase(f"dispositif {key!r} has no rule for income year {r.annee_revenus}")
        d = r.dispositifs[key]
        notes: dict[str, Decimal] = {}
        match a:
            case Dons():
                montant, reports, notes = _dons(a, rni, d, f.annee_revenus)
            case EmploiDomicile():
                montant = _emploi_domicile(a, d)
            case GardeEnfant():
                assert d.taux is not None and d.plafond is not None
                montant = sum((min(x, d.plafond) * d.taux for x in a.depenses_par_enfant), ZERO)
            case Scolarite():
                montant = (a.college * _param(d, key, "college") + a.lycee * _param(d, key, "lycee")
                           + a.superieur * _param(d, key, "superieur"))
            case Souscription():
                assert d.taux is not None
                total = a.montant + a.montant_taux_majore
                plafond = (d.plafond_couple if f.couple and d.plafond_couple else d.plafond) or total
                if "plafond_pct_rng" in d.params:
                    plafond = min(plafond, rng * d.params["plafond_pct_rng"])
                if total > plafond:
                    t.warn(f"{key}: {total - plafond} above the yearly cap is not taken into account "
                           "(carry-forward, where it exists, is not modelled)")
                # Under a shared cap, the higher-rate tranche is assumed to be retained first.
                majore = min(a.montant_taux_majore, plafond)
                if majore:
                    montant = majore * _param(d, key, "taux_majore")
                    notes["base_taux_majore"] = majore
                else:
                    montant = ZERO
                base = min(a.montant, plafond - majore)
                montant += base * d.taux
                notes["base"] = base
            case ReductionDirecte():
                montant = a.reduction
            case _:
                raise UnsupportedCase(f"dispositif {key!r} not handled")
        out.append(AvantageCalcule(key, d, euro_round(montant), notes))
    return out, reports


@dataclass(frozen=True)
class Imputation:
    impot_apres_reductions: Decimal
    reductions_imputees: Decimal
    reductions_perdues: Decimal
    credits: Decimal
    reprise_niches: Decimal


def imputer(impot: Decimal, avs: list[AvantageCalcule], r: RuleSet, t: Trace) -> Imputation:
    used: dict[str, Decimal] = {}
    remaining = impot
    perdues = ZERO
    for av in sorted((a for a in avs if a.rule.nature == "reduction"), key=lambda a: a.rule.ordre):
        u = min(remaining, av.montant)
        remaining -= u
        perdues += av.montant - u
        used[av.key] = u
        t.add(f"reduction.{av.key}", [av.rule.source], theorique=av.montant, imputee=u,
              perdue=av.montant - u, **av.notes)
    credits = ZERO
    for av in (a for a in avs if a.rule.nature == "credit"):
        used[av.key] = av.montant
        credits += av.montant
        t.add(f"credit.{av.key}", [av.rule.source], montant=av.montant, **av.notes)

    by_key = {a.key: a for a in avs}
    g = sum((u * by_key[k].rule.quote_part_plafond for k, u in used.items()
             if by_key[k].rule.bucket == Bucket.GLOBAL), ZERO)
    m = sum((u * by_key[k].rule.quote_part_plafond for k, u in used.items()
             if by_key[k].rule.bucket == Bucket.MAJORE), ZERO)
    n = r.niches
    reprise = euro_round(clamp0(g - n.plafond_global) + clamp0(min(g, n.plafond_global) + m - n.plafond_majore))
    t.add("plafonnement_niches", ["CGI 200-0 A"], avantages_plafond_global=g,
          avantages_plafond_majore=m, reprise=reprise)
    return Imputation(remaining, impot - remaining, perdues, credits, reprise)
