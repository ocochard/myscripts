"""The DGFIP liquidation sequence, from categorical income to the balance due."""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from pydantic import BaseModel

from ..foyer import Declarant, FoyerFiscal, ReportDon
from ..money import ZERO, clamp0, euro_round
from ..rules import RuleSet
from . import avantages
from .quotient import droits_simples
from .revenus import revenus_categoriels
from .trace import Step, Trace, UnsupportedCase


class Reports(BaseModel):
    """Carry-forwards produced for income year N+1."""

    deficit_foncier: Decimal = ZERO  # => 4BD
    deficit_global: Decimal = ZERO  # => 6FA..6FL
    dons: list[ReportDon] = []  # => 7XS..
    csg_deductible: Decimal = ZERO  # => 6DE of N+1


class Resultat(BaseModel):
    annee_revenus: int
    parts: Decimal
    rbg: Decimal
    rni: Decimal
    tmi: Decimal
    droits_simples: Decimal
    decote: Decimal
    reductions: Decimal
    impot_proportionnel: Decimal
    credits: Decimal
    reprise_niches: Decimal
    rfr: Decimal
    cehr: Decimal
    impot_net: Decimal  # IR + contributions, after crédits (can be < 0 => refund)
    prelevements_sociaux: Decimal
    solde_ir: Decimal  # > 0 to pay, < 0 refunded, after PAS/acomptes
    reports: Reports
    steps: list[Step]
    warnings: list[str]
    regles_non_verifiees: list[str]


def _age(d: Declarant, annee: int) -> int:
    end = date(annee, 12, 31)
    return end.year - d.naissance.year - ((end.month, end.day) < (d.naissance.month, d.naissance.day))


def _charges(f: FoyerFiscal, r: RuleSet, t: Trace) -> tuple[Decimal, Decimal]:
    """Return (total deductible charges, PER deduction) - the latter is added back into the RFR."""
    if f.couple and f.per_mutualisation and any(d.per_versements for d in f.declarants):
        # 6QR: plafonds pooled between spouses.
        vers = sum((d.per_versements for d in f.declarants), ZERO)
        plafonds = [d.per_plafond_disponible for d in f.declarants]
        if any(p is None for p in plafonds):
            raise ValueError("per_plafond_disponible (from the avis N-1) is required when per_versements > 0")
        per = min(vers, sum(plafonds, ZERO))  # type: ignore[arg-type]
    else:
        per = ZERO
        for d in f.declarants:
            if d.per_versements:
                if d.per_plafond_disponible is None:
                    raise ValueError("per_plafond_disponible (from the avis N-1) is required when per_versements > 0")
                per += min(d.per_versements, d.per_plafond_disponible)
    for p in f.personnes_a_charge:  # 6NU: own plafond, never pooled (6QR is between spouses)
        if p.per_versements:
            if p.per_plafond_disponible is None:
                raise ValueError("per_plafond_disponible is required for a dependant's PER payments")
            per += min(p.per_versements, p.per_plafond_disponible)
    c = f.charges
    cap = r.charges.plafond_pension_enfant_majeur
    pensions = sum((min(x, cap) for x in c.pensions_enfants_majeurs), ZERO) + c.pensions_autres
    total = per + pensions + c.csg_deductible
    t.add("charges_deductibles", ["CGI 156-II", "CGI 163 quatervicies", "CGI 154 quinquies"],
          per=per, pensions_alimentaires=pensions, csg_deductible=c.csg_deductible, total=total)
    return total, per


def _abattement_age(f: FoyerFiscal, rng: Decimal, r: RuleSet) -> Decimal:
    a = r.abattement_age
    n = sum(1 for d in f.declarants if d.invalide or _age(d, f.annee_revenus) >= a.age)
    if rng <= a.seuil_1:
        unit = a.montant_1
    elif rng <= a.seuil_2:
        unit = a.montant_2
    else:
        unit = ZERO
    return n * unit


def _contribution(base: Decimal, tranches) -> Decimal:
    out = ZERO
    for i, tr in enumerate(tranches):
        upper = tranches[i + 1].seuil if i + 1 < len(tranches) else None
        if base > tr.seuil:
            out += ((base if upper is None else min(base, upper)) - tr.seuil) * tr.taux
    return out


def compute(f: FoyerFiscal, r: RuleSet) -> Resultat:
    if f.annee_revenus != r.annee_revenus:
        raise ValueError(f"foyer is income year {f.annee_revenus}, rules are {r.annee_revenus}")
    t = Trace()

    # 1-3. Categorical income => revenu brut global.
    cat = revenus_categoriels(f, r, t)
    brut = sum(cat.par_declarant, ZERO) + cat.capitaux_bareme + cat.fonciers - cat.deficit_foncier_global
    rbg_avant_reports = brut - f.charges.deficits_globaux_anterieurs
    rbg = clamp0(rbg_avant_reports)
    deficit_global = clamp0(-rbg_avant_reports)
    t.add("revenu_brut_global", ["CGI 156"], total=brut,
          deficits_anterieurs=f.charges.deficits_globaux_anterieurs, rbg=rbg, deficit_reporte=deficit_global)

    # 4. Charges and special allowances => revenu net imposable.
    charges, per = _charges(f, r, t)
    rng = clamp0(rbg - charges)
    ab_age = _abattement_age(f, rng, r)
    rni = euro_round(clamp0(rng - ab_age))  # CGI 193: nearest euro
    t.add("revenu_net_imposable", ["CGI 157 bis"], rng=rng, abattement_age=ab_age, rni=rni)

    # 5-6. Barème with QF cap, then décote.
    ds = droits_simples(f, rni, r, t)

    # 7. Réductions, limited to the barème tax after décote; 8. then proportional taxes are added
    # (fiche de calcul 2042, brochure IR 2026 p.381: "total ... limité au montant C", then "E + n").
    pfu = euro_round(cat.pfu_base * r.capitaux.pfu_taux_ir)
    avs, reports_dons = avantages.theoriques(f, rni, rng, r, t)
    imp = avantages.imputer(ds.apres_decote, avs, r, t)
    apres_reductions = imp.impot_apres_reductions + pfu
    t.add("impot_proportionnel", ["CGI 200 A-1-A-1°"], base=cat.pfu_base, taux=r.capitaux.pfu_taux_ir, impot=pfu)

    # 11. RFR and high-income contributions.
    c = f.capitaux
    # Exempt overtime enters the RFR net of the 10 % allowance: the brochure (p.335) only says
    # "salaires des heures supplémentaires exonérées", the net treatment was matched on a real avis.
    heures_sup = ZERO
    for d in f.declarants:
        if d.heures_sup_exonerees and d.frais_reels is not None:
            raise UnsupportedCase("exempt overtime with frais réels: RFR treatment not modelled")
        heures_sup += d.heures_sup_exonerees * (1 - r.abattement_salaires.taux)
    rfr = rni + cat.pfu_base + per + heures_sup
    if c.option_bareme:
        rfr += c.dividendes * r.capitaux.abattement_dividendes + c.abattement_duree_detention
    rfr = euro_round(rfr)
    t.warn("RFR: adds back PFU income, PER deduction, exempt overtime, 40 % abatement and 3SG only; "
           "other exempt income listed in CGI 1417-IV (tips, PPV...) is not modelled")
    tranches = r.cehr.couple if f.couple else r.cehr.seul
    cehr = euro_round(_contribution(Decimal(rfr), tranches))
    seuil_cdhr = r.cdhr.seuil_couple if f.couple else r.cdhr.seuil_seul
    if r.cdhr.applicable and seuil_cdhr is not None and rfr > seuil_cdhr:
        raise UnsupportedCase(f"RFR {rfr} above the CDHR threshold {seuil_cdhr}: CDHR not modelled")
    t.add("contributions_hauts_revenus", ["CGI 1417-IV", "CGI 223 sexies"], per_reintegre=per, heures_sup=heures_sup, rfr=rfr, cehr=cehr)

    # 9-10. Crédits (refundable), 2CK, niche cap claw-back; 12. collection thresholds and balance.
    credits = imp.credits + c.prelevement_forfaitaire_acquitte
    avant_credits = apres_reductions + imp.reprise_niches + cehr
    rc = r.recouvrement
    if 0 < avant_credits < rc.seuil_mise_en_recouvrement:
        t.warn(f"tax {avant_credits} below {rc.seuil_mise_en_recouvrement}: not collected")
        avant_credits = ZERO
    impot_net = avant_credits - credits
    p = f.prelevements
    solde = impot_net - p.pas_preleve - p.acomptes + p.avance_credits
    if -rc.seuil_restitution < solde < 0:
        t.warn(f"refund {-solde} below {rc.seuil_restitution}: not paid")
        solde = ZERO
    t.add("impot_net", ["CGI 1657", "CGI 1965 L"], avant_credits=avant_credits, credits=credits,
          impot_net=impot_net, pas=p.pas_preleve, acomptes=p.acomptes,
          avance_credits=p.avance_credits, solde=solde)

    # Prélèvements sociaux on patrimony income assessed through the return.
    ps_r = r.prelevements_sociaux
    bases = {"fonciers": cat.fonciers, "bic_non_pro": cat.bic_non_pro, "plus_values": cat.plus_values}
    if not c.ps_deja_preleves_rcm:
        bases["rcm"] = c.dividendes + c.interets
    ps = ZERO
    csg_ded = ZERO
    for nature, base in bases.items():
        if not base:
            continue
        if nature not in ps_r.taux:
            raise UnsupportedCase(f"no PS rate for income nature {nature!r}")
        ps += base * ps_r.taux[nature]
        au_bareme = nature in ("fonciers", "bic_non_pro") or c.option_bareme
        if au_bareme:
            csg_ded += base * ps_r.csg_deductible.get(nature, ZERO)
    if c.option_bareme and c.ps_deja_preleves_rcm:  # CSG withheld at source is still deductible
        csg_ded += (c.dividendes + c.interets) * ps_r.csg_deductible.get("rcm", ZERO)
    ps = euro_round(ps)
    t.add("prelevements_sociaux", ["CSS L136-6", "CGI 1600-0 S"],
          **{f"base_{k}": v for k, v in bases.items()}, total=ps, csg_deductible_n1=euro_round(csg_ded))

    rb = r.unverified()
    if rb:
        t.warn(f"rule sections not verified against primary sources: {', '.join(rb)}")

    return Resultat(
        annee_revenus=f.annee_revenus, parts=ds.parts.total, rbg=rbg, rni=rni, tmi=ds.tmi,
        droits_simples=ds.droits, decote=ds.decote, reductions=imp.reductions_imputees,
        impot_proportionnel=pfu, credits=credits, reprise_niches=imp.reprise_niches, rfr=rfr,
        cehr=cehr, impot_net=impot_net, prelevements_sociaux=ps, solde_ir=solde,
        reports=Reports(deficit_foncier=cat.deficit_foncier_reporte, deficit_global=deficit_global,
                        dons=reports_dons, csg_deductible=euro_round(csg_ded)),
        steps=t.steps, warnings=t.warnings, regles_non_verifiees=rb,
    )
