"""Step 1: net categorical income (revenus catégoriels nets)."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from ..foyer import Declarant, FonciersMicro, FonciersReel, FoyerFiscal
from ..money import ZERO, clamp0
from ..rules import RuleSet
from .trace import Trace, UnsupportedCase


def _abattement_salaires(d: Declarant, r: RuleSet) -> Decimal:
    if d.frais_reels is not None:
        return min(d.frais_reels, d.salaires)
    a = r.abattement_salaires
    return min(d.salaires, min(a.maximum, max(a.minimum, d.salaires * a.taux)))


def _abattements_pensions(decls: list[Declarant], r: RuleSet) -> list[Decimal]:
    a = r.abattement_pensions
    per = [min(d.pensions, max(a.minimum_par_personne, d.pensions * a.taux)) for d in decls]
    total = sum(per, ZERO)
    if total > a.maximum_foyer:  # cap is per foyer, shared pro rata
        per = [a.maximum_foyer * p / total for p in per]
    return per


def _micro(recettes: Decimal, taux: Decimal, seuil: Decimal, minimum: Decimal, what: str) -> Decimal:
    if recettes > seuil:
        raise UnsupportedCase(f"{what}: recettes {recettes} above the micro threshold {seuil}")
    if recettes == 0:
        return ZERO
    return recettes - min(recettes, max(minimum, recettes * taux))


@dataclass(frozen=True)
class Categoriels:
    par_declarant: list[Decimal]
    capitaux_bareme: Decimal
    fonciers: Decimal
    deficit_foncier_global: Decimal
    pfu_base: Decimal
    bic_non_pro: Decimal  # PS base
    plus_values: Decimal  # PS base
    deficit_foncier_reporte: Decimal


def revenus_categoriels(f: FoyerFiscal, r: RuleSet, t: Trace) -> Categoriels:
    mi = r.micro
    pensions_ab = _abattements_pensions(f.declarants, r)
    par_decl: list[Decimal] = []
    bic_non_pro = ZERO
    for i, d in enumerate(f.declarants, 1):
        sal_ab = _abattement_salaires(d, r)
        bic = ZERO
        for b in d.bic_micro:
            if b.nature not in mi.bic:
                raise UnsupportedCase(f"micro-BIC nature {b.nature!r} not in rules ({sorted(mi.bic)})")
            p = mi.bic[b.nature]
            bic += _micro(b.recettes, p.abattement, p.seuil, mi.abattement_minimum, f"micro-BIC {b.nature}")
        bnc = _micro(d.bnc_micro, mi.bnc.abattement, mi.bnc.seuil, mi.abattement_minimum, "micro-BNC")
        bic_non_pro += bic + d.bic_non_pro_reel
        net = (d.salaires - sal_ab) + (d.pensions - pensions_ab[i - 1]) + bic + bnc + d.bic_non_pro_reel
        par_decl.append(net)
        t.add(
            f"revenus.declarant{i}",
            ["CGI 83-3°", "CGI 158-5-a", "CGI 50-0", "CGI 102 ter"],
            salaires=d.salaires, abattement_salaires=sal_ab,
            pensions=d.pensions, abattement_pensions=pensions_ab[i - 1],
            bic=bic + d.bic_non_pro_reel, bnc=bnc, net=net,
        )

    c = f.capitaux
    if c.option_bareme:
        cap_bareme = c.dividendes * (1 - r.capitaux.abattement_dividendes) + c.interets
        cap_bareme += clamp0(c.plus_values - c.abattement_duree_detention)
        pfu_base = ZERO
    else:
        if c.abattement_duree_detention:
            raise ValueError("3SG (abattement durée de détention) requires the barème option (2OP)")
        cap_bareme = ZERO
        pfu_base = c.dividendes + c.interets + c.plus_values
    t.add("revenus.capitaux", ["CGI 200 A", "CGI 158-3-2°"],
          option_bareme=c.option_bareme, imposable_bareme=cap_bareme, base_pfu=pfu_base)

    fonciers = deficit_global = reporte = ZERO
    match f.fonciers:
        case FonciersMicro(recettes=rec):
            fonciers = _micro(rec, mi.foncier.abattement, mi.foncier.seuil, ZERO, "micro-foncier")
        case FonciersReel() as fr:
            df = r.deficit_foncier
            cap = df.plafond_renovation_energetique if fr.renovation_energetique else df.plafond_global
            if fr.deficit_imputable_global > cap:
                raise ValueError(f"4BC {fr.deficit_imputable_global} exceeds the cap {cap}")
            if fr.resultat and (fr.deficit_imputable_fonciers or fr.deficit_imputable_global):
                raise ValueError("4BA and 4BB/4BC are mutually exclusive on the 2044")
            fonciers = clamp0(fr.resultat - fr.deficits_anterieurs)
            reporte = clamp0(fr.deficits_anterieurs - fr.resultat) + fr.deficit_imputable_fonciers
            deficit_global = fr.deficit_imputable_global
    if f.fonciers is not None:
        t.add("revenus.fonciers", ["CGI 32", "CGI 156-I-3°"], regime=f.fonciers.regime,
              net=fonciers, deficit_imputable_global=deficit_global, deficit_reporte=reporte)

    return Categoriels(par_decl, cap_bareme, fonciers, deficit_global, pfu_base,
                       bic_non_pro, c.plus_values, reporte)
