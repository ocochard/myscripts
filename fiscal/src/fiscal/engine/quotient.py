"""Parts, barème, plafonnement du quotient familial and décote (CGI 193-197)."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from ..foyer import FoyerFiscal, Situation
from ..money import ZERO, euro_round
from ..rules import Bareme, RuleSet
from .trace import Trace, UnsupportedCase

HALF = Decimal("0.5")
QUARTER = Decimal("0.25")


@dataclass(frozen=True)
class Parts:
    total: Decimal
    reference: Decimal  # parts the QF advantage is measured against
    general: Decimal  # extra parts capped at plafond_demi_part
    parent_isole: Decimal  # extra parts capped at plafond_parent_isole (case T)
    case_l: Decimal


def compute_parts(f: FoyerFiscal) -> Parts:
    pac = f.personnes_a_charge
    if f.situation == Situation.VEUF and pac:
        raise UnsupportedCase("veuf with dependants: specific QF cap and réduction complémentaire not modelled")
    reference = Decimal(2) if f.couple else Decimal(1)

    # Exclusive-custody children rank before shared-custody ones (CGI 194-I).
    ranked = sorted(pac, key=lambda p: p.garde_alternee)
    enfants = ZERO
    for rank, p in enumerate(ranked, 1):
        share = Decimal(1) if rank >= 3 else HALF
        if p.invalide:
            share += HALF
        enfants += share / 2 if p.garde_alternee else share

    general = enfants
    parent_isole = ZERO
    single = f.situation in (Situation.CELIBATAIRE, Situation.DIVORCE)
    if single and pac and not f.vit_en_couple:  # case T: +0.5 (0.25 if only shared custody)
        first = ranked[0]
        bonus = QUARTER if first.garde_alternee else HALF
        first_child = QUARTER if first.garde_alternee else HALF
        parent_isole = bonus + first_child
        general -= first_child

    for d in f.declarants:
        if d.invalide or d.ancien_combattant:
            raise UnsupportedCase("case P/W half-part: complementary réduction not modelled")

    case_l = HALF if f.case_l else ZERO
    total = reference + general + parent_isole + case_l
    return Parts(total, reference, general, parent_isole, case_l)


def bareme(revenu: Decimal, b: Bareme) -> Decimal:
    tax = ZERO
    ts = b.tranches
    for i, tr in enumerate(ts):
        upper = ts[i + 1].seuil if i + 1 < len(ts) else None
        if revenu <= tr.seuil:
            break
        top = revenu if upper is None else min(revenu, upper)
        tax += (top - tr.seuil) * tr.taux
    return tax


def tmi(revenu_par_part: Decimal, b: Bareme) -> Decimal:
    rate = ZERO
    for tr in b.tranches:
        if revenu_par_part > tr.seuil:
            rate = tr.taux
    return rate


@dataclass(frozen=True)
class DroitsSimples:
    parts: Parts
    droits: Decimal  # after QF cap, before décote, rounded
    decote: Decimal
    apres_decote: Decimal
    tmi: Decimal


def droits_simples(f: FoyerFiscal, rni: Decimal, r: RuleSet, t: Trace) -> DroitsSimples:
    p = compute_parts(f)
    qf = r.quotient_familial
    full = p.total * bareme(rni / p.total, r.bareme)
    ref_parts = p.reference
    capped = ref_parts * bareme(rni / ref_parts, r.bareme)
    cap = (
        p.general * 2 * qf.plafond_demi_part
        + p.parent_isole * qf.plafond_parent_isole  # 1 part => full cap, 0.5 => half
        + p.case_l * 2 * qf.plafond_case_l
    )
    plafonne = capped - cap > full
    droits = euro_round(max(full, capped - cap))
    t.add(
        "quotient_familial", ["CGI 194", "CGI 195", "CGI 197-I-1", "CGI 197-I-2"],
        parts=p.total, quotient=rni / p.total, impot_parts_totales=euro_round(full),
        impot_parts_reference=euro_round(capped), plafond_avantage=cap,
        plafonnement_applique=plafonne, droits=droits,
    )

    d = r.decote
    forfait = d.forfait_couple if f.couple else d.forfait_seul
    decote = euro_round(min(droits, max(ZERO, forfait - d.taux * droits)))
    t.add("decote", ["CGI 197-I-4"], forfait=forfait, decote=decote, apres_decote=droits - decote)
    rate = tmi(rni / p.total, r.bareme) if not plafonne else tmi(rni / ref_parts, r.bareme)
    return DroitsSimples(p, droits, decote, droits - decote, rate)
