"""Optimizer: allocate a cash budget across tax levers by risk-adjusted economic value.

The engine is the only tax oracle: every candidate step is priced by running
`engine.compute` on the modified household, so interactions (TMI changes,
QF cap, décote, réductions exceeding the tax, global niche cap) are exact.

Each lever turns (amount, exact tax saving) into a net present value using the
user's assumptions: the tax saving is not the gain. A PER deduction is a
deferral taxed at exit, an FCPI saving comes with fees and locked, risky
capital, a Girardin réduction is bought with cash that never comes back.

Algorithm (deterministic):
1. Enumerate the discrete choices (PFU vs barème option).
2. For each, greedily commit the budget step by step to the lever with the
   best marginal NPV per euro, re-running the engine after every step;
   stop when no step has a positive NPV or the budget is spent.
3. Keep the choice with the highest total NPV.
Risk class and lock-in are hard filters, not weights.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from enum import IntEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from .engine import compute
from .foyer import FoyerFiscal, ReductionDirecte, Souscription
from .money import ZERO, Money, Rate
from .rules import RuleSet

ONE = Decimal(1)


class Risque(IntEnum):
    FAIBLE = 1
    MODERE = 2
    ELEVE = 3
    TRES_ELEVE = 4


RisqueNom = Literal["faible", "modere", "eleve", "tres_eleve"]


def _risque(n: RisqueNom) -> Risque:
    return Risque[n.upper()]


# ---------------------------------------------------------------- assumptions

class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class HypPER(Strict):
    rendement: Decimal  # yearly gross return
    frais: Decimal = ZERO  # yearly fees
    annees_avant_retraite: int = Field(ge=1)
    tmi_sortie: Rate  # expected marginal rate when the capital is withdrawn
    risque: RisqueNom = "modere"


class HypFonds(Strict):
    """FCPI / FIP / direct PME: capital locked, gains exempt from IR, PS on gains."""

    rendement: Decimal = ZERO
    frais: Decimal = ZERO
    blocage_ans: int = Field(ge=1)
    risque: RisqueNom = "tres_eleve"
    tranche_majoree: bool = False  # book into montant_taux_majore (e.g. FCPI 25 %)


class HypSofica(Strict):
    valeur_rachat: Rate  # fraction of capital returned at exit
    blocage_ans: int = Field(ge=1)
    risque: RisqueNom = "eleve"


class HypGirardin(Strict):
    taux_reduction: Decimal = Field(gt=1)  # réduction per euro invested (e.g. 1.12)
    risque: RisqueNom = "modere"  # operator / requalification risk; the cash never comes back


class Leviers(Strict):
    per: HypPER | None = None
    fcpi: HypFonds | None = None
    fip_corse_outremer: HypFonds | None = None
    pme_ir: HypFonds | None = None
    sofica: HypSofica | None = None
    girardin_industriel: HypGirardin | None = None


class Hypotheses(Strict):
    annee_revenus: int
    budget: Money
    taux_actualisation: Decimal  # return of the alternative use of the cash
    risque_max: RisqueNom
    blocage_max_ans: int
    pas: Money = Decimal(250)
    delai_economie_ans: Decimal = ONE  # tax saving arrives with the N+1 balance
    tester_option_bareme: bool = True
    leviers: Leviers


# ---------------------------------------------------------------- levers

def _objective(f: FoyerFiscal, r: RuleSet) -> Decimal:
    res = compute(f, r)
    return res.impot_net + res.prelevements_sociaux


def _disc(x: Decimal, years: Decimal | int, d: Decimal) -> Decimal:
    return x / (ONE + d) ** Decimal(years)


@dataclass(frozen=True)
class Lever:
    key: str
    risque: Risque
    blocage: int

    def headroom(self, f: FoyerFiscal, r: RuleSet) -> Decimal | None:
        """Max extra amount, None = bounded only by budget (the engine prices the rest)."""
        raise NotImplementedError

    def apply(self, f: FoyerFiscal, amount: Decimal) -> FoyerFiscal:
        raise NotImplementedError

    def npv(self, amount: Decimal, saving: Decimal, h: Hypotheses, r: RuleSet) -> Decimal:
        raise NotImplementedError


@dataclass(frozen=True)
class PER(Lever):
    hyp: HypPER

    @staticmethod
    def _room(d) -> Decimal:
        return ZERO if d.per_plafond_disponible is None else max(ZERO, d.per_plafond_disponible - d.per_versements)

    def headroom(self, f, r):
        pac = sum((self._room(p) for p in f.personnes_a_charge), ZERO)
        if f.per_mutualisation:
            if any(d.per_plafond_disponible is None for d in f.declarants):
                return pac
            used = sum((d.per_versements for d in f.declarants), ZERO)
            return pac + max(ZERO, sum((d.per_plafond_disponible for d in f.declarants), ZERO) - used)  # type: ignore[misc]
        return pac + sum((self._room(d) for d in f.declarants), ZERO)

    def apply(self, f, amount):
        """Spread the step over the remaining plafonds so no euro lands above one.

        Order: declarants (pooled under 6QR), then rattached dependants' own PER,
        which are deducted from the same foyer income.
        """
        ds = list(f.declarants)
        ps = list(f.personnes_a_charge)
        left = amount
        if f.per_mutualisation and all(d.per_plafond_disponible is not None for d in ds):
            pooled = max(ZERO, sum((d.per_plafond_disponible for d in ds), ZERO)  # type: ignore[misc]
                         - sum((d.per_versements for d in ds), ZERO))
            put = min(left, pooled)
            ds[0] = ds[0].model_copy(update={"per_versements": ds[0].per_versements + put})
            left -= put
        else:
            for k, d in enumerate(ds):
                put = min(left, self._room(d))
                if put:
                    ds[k] = d.model_copy(update={"per_versements": d.per_versements + put})
                    left -= put
        for k, p in enumerate(ps):
            put = min(left, self._room(p))
            if put:
                ps[k] = p.model_copy(update={"per_versements": p.per_versements + put})
                left -= put
        if left:
            raise ValueError("PER step larger than the remaining plafonds")
        return f.model_copy(update={"declarants": ds, "personnes_a_charge": ps})

    def npv(self, amount, saving, h, r):
        p = self.hyp
        n = p.annees_avant_retraite
        fv = (ONE + p.rendement - p.frais) ** n
        gain = max(ZERO, fv - ONE)
        flat = r.capitaux.pfu_taux_ir + r.prelevements_sociaux.taux.get("rcm", ZERO)
        exit_net = fv - p.tmi_sortie - gain * flat  # capital exit: principal at barème, gain at PFU
        d = h.taux_actualisation
        return -amount + _disc(saving, h.delai_economie_ans, d) + _disc(amount * exit_net, n, d)


@dataclass(frozen=True)
class SouscriptionLever(Lever):
    """Subscriptions entered as an amount (FCPI, FIP, IR-PME, SOFICA)."""

    majoree: bool  # book into montant_taux_majore

    def _current(self, f: FoyerFiscal) -> Souscription | None:
        return next((a for a in f.avantages if a.dispositif == self.key), None)  # type: ignore[return-value]

    def headroom(self, f, r):
        rule = r.dispositifs.get(self.key)
        if rule is None:
            return ZERO
        cap = rule.plafond_couple if f.couple and rule.plafond_couple else rule.plafond
        if cap is None:
            return None
        cur = self._current(f)
        return cap - ((cur.montant + cur.montant_taux_majore) if cur else ZERO)

    def apply(self, f, amount):
        field = "montant_taux_majore" if self.majoree else "montant"
        cur = self._current(f)
        others = [a for a in f.avantages if a.dispositif != self.key]
        if cur is None:
            new = Souscription(dispositif=self.key, **{field: amount})  # type: ignore[arg-type]
        else:
            new = cur.model_copy(update={field: getattr(cur, field) + amount})
        return f.model_copy(update={"avantages": [*others, new]})


@dataclass(frozen=True)
class Fonds(SouscriptionLever):
    hyp: HypFonds

    def npv(self, amount, saving, h, r):
        p = self.hyp
        fv = (ONE + p.rendement - p.frais) ** p.blocage_ans
        ps = r.prelevements_sociaux.taux.get("plus_values", ZERO)
        exit_net = fv - max(ZERO, fv - ONE) * ps
        d = h.taux_actualisation
        return -amount + _disc(saving, h.delai_economie_ans, d) + _disc(amount * exit_net, p.blocage_ans, d)


@dataclass(frozen=True)
class Sofica(SouscriptionLever):
    hyp: HypSofica

    def npv(self, amount, saving, h, r):
        p = self.hyp
        d = h.taux_actualisation
        return -amount + _disc(saving, h.delai_economie_ans, d) + _disc(amount * p.valeur_rachat, p.blocage_ans, d)


@dataclass(frozen=True)
class Girardin(Lever):
    hyp: HypGirardin

    def headroom(self, f, r):
        return None if "girardin_industriel" in r.dispositifs else ZERO

    def apply(self, f, amount):
        red = amount * self.hyp.taux_reduction
        cur = next((a for a in f.avantages if a.dispositif == "girardin_industriel"), None)
        others = [a for a in f.avantages if a.dispositif != "girardin_industriel"]
        new = (ReductionDirecte(dispositif="girardin_industriel", reduction=red) if cur is None
               else cur.model_copy(update={"reduction": cur.reduction + red}))  # type: ignore[union-attr]
        return f.model_copy(update={"avantages": [*others, new]})

    def npv(self, amount, saving, h, r):
        return -amount + _disc(saving, h.delai_economie_ans, h.taux_actualisation)


def build_levers(h: Hypotheses) -> list[Lever]:
    lv = h.leviers
    out: list[Lever] = []
    if lv.per:
        out.append(PER("per", _risque(lv.per.risque), lv.per.annees_avant_retraite, lv.per))
    for key in ("fcpi", "fip_corse_outremer", "pme_ir"):
        hyp = getattr(lv, key)
        if hyp:
            out.append(Fonds(key, _risque(hyp.risque), hyp.blocage_ans, hyp.tranche_majoree, hyp))
    if lv.sofica:
        out.append(Sofica("sofica", _risque(lv.sofica.risque), lv.sofica.blocage_ans, False, lv.sofica))
    if lv.girardin_industriel:
        out.append(Girardin("girardin_industriel", _risque(lv.girardin_industriel.risque), 0,
                            lv.girardin_industriel))
    return out


# ---------------------------------------------------------------- result

class Segment(BaseModel):
    de: Decimal
    a: Decimal
    economie_par_euro: Decimal  # exact marginal tax saving per euro on this range


class Allocation(BaseModel):
    levier: str
    montant: Decimal
    economie_impot: Decimal
    van: Decimal  # net present value of the whole allocation
    blocage_ans: int
    risque: str
    segments: list[Segment]


class Ecarte(BaseModel):
    levier: str
    raison: str


class Plan(BaseModel):
    annee_revenus: int
    option_bareme: bool
    impot_initial: Decimal  # IR + PS before the plan, chosen option excluded
    impot_final: Decimal
    economie_totale: Decimal
    van_totale: Decimal
    cash_engage: Decimal
    allocations: list[Allocation]
    ecartes: list[Ecarte]
    premier_euro: dict[str, tuple[Decimal, Decimal]]  # lever -> (saving/€, NPV/€) on the first step
    alternative: dict[str, Decimal] | None = None  # the discrete option not retained
    avertissements: list[str]


# ---------------------------------------------------------------- solver

def _greedy(f0: FoyerFiscal, levers: list[Lever], h: Hypotheses, r: RuleSet):
    f = f0
    cur = _objective(f, r)
    remaining = h.budget
    steps: dict[str, list[tuple[Decimal, Decimal, Decimal]]] = {lv.key: [] for lv in levers}  # (amount, saving, npv)
    first: dict[str, tuple[Decimal, Decimal]] = {}
    while remaining > 0:
        best = None
        for lv in levers:
            room = lv.headroom(f, r)
            amt = min(h.pas, remaining) if room is None else min(h.pas, remaining, room)
            if amt <= 0:
                continue
            nf = lv.apply(f, amt)
            obj = _objective(nf, r)
            saving = cur - obj
            v = lv.npv(amt, saving, h, r)
            first.setdefault(lv.key, (saving / amt, v / amt))
            score = v / amt
            if best is None or score > best[0]:
                best = (score, lv, amt, nf, obj, saving, v)
        if best is None or best[0] <= 0:
            break
        _, lv, amt, nf, obj, saving, v = best
        steps[lv.key].append((amt, saving, v))
        f, cur, remaining = nf, obj, remaining - amt
    return f, cur, steps, first


def _segments(steps: list[tuple[Decimal, Decimal, Decimal]]) -> list[Segment]:
    segs: list[Segment] = []
    pos = ZERO
    for amt, saving, _ in steps:
        rate = (saving / amt).quantize(Decimal("0.01"))
        if segs and segs[-1].economie_par_euro == rate:
            segs[-1].a = pos + amt
        else:
            segs.append(Segment(de=pos, a=pos + amt, economie_par_euro=rate))
        pos += amt
    return segs


def optimize(f: FoyerFiscal, h: Hypotheses, r: RuleSet) -> Plan:
    if not (f.annee_revenus == h.annee_revenus == r.annee_revenus):
        raise ValueError("foyer, hypotheses and rules must share the same income year")
    warnings = list(compute(f, r).warnings)
    levers, ecartes = [], []
    for lv in build_levers(h):
        if lv.risque > _risque(h.risque_max):
            ecartes.append(Ecarte(levier=lv.key, raison=f"risque {lv.risque.name.lower()} > {h.risque_max}"))
        elif lv.blocage > h.blocage_max_ans:
            ecartes.append(Ecarte(levier=lv.key, raison=f"blocage {lv.blocage} ans > {h.blocage_max_ans}"))
        elif lv.headroom(f, r) == 0:
            ecartes.append(Ecarte(levier=lv.key, raison="no headroom (cap reached, no rule, or PER plafond unknown)"))
        else:
            levers.append(lv)

    options = [f.capitaux.option_bareme]
    has_capital = f.capitaux.dividendes or f.capitaux.interets or f.capitaux.plus_values
    if h.tester_option_bareme and has_capital and not f.capitaux.abattement_duree_detention:
        options = [False, True]

    runs = []
    base_obj = _objective(f, r)
    for opt in options:
        fo = f.model_copy(update={"capitaux": f.capitaux.model_copy(update={"option_bareme": opt})})
        start = _objective(fo, r)
        ff, end, steps, first = _greedy(fo, levers, h, r)
        van = sum((v for s in steps.values() for _, _, v in s), ZERO)
        # The option switch itself costs no cash: its saving is pure value.
        van_total = van + _disc(base_obj - start, h.delai_economie_ans, h.taux_actualisation)
        runs.append((van_total, opt, start, end, steps, first))
    runs.sort(key=lambda x: (-x[0], x[1]))
    van_total, opt, start, end, steps, first = runs[0]

    allocations = []
    for lv in levers:
        s = steps[lv.key]
        if not s:
            continue
        allocations.append(Allocation(
            levier=lv.key, montant=sum((a for a, _, _ in s), ZERO),
            economie_impot=sum((x for _, x, _ in s), ZERO), van=sum((v for _, _, v in s), ZERO),
            blocage_ans=lv.blocage, risque=lv.risque.name.lower(), segments=_segments(s)))
    alt = None
    if len(runs) > 1:
        o = runs[1]
        alt = {"option_bareme": Decimal(int(o[1])), "van_totale": o[0], "impot_final": o[3]}
    return Plan(
        annee_revenus=f.annee_revenus, option_bareme=opt, impot_initial=base_obj, impot_final=end,
        economie_totale=base_obj - end, van_totale=van_total,
        cash_engage=sum((a.montant for a in allocations), ZERO), allocations=allocations,
        ecartes=ecartes, premier_euro=first, alternative=alt, avertissements=warnings)
