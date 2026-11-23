"""Optimizer tests on the synthetic 2099 rule set (hand-computed expectations)."""

from decimal import Decimal as D
from pathlib import Path

from fiscal.foyer import FoyerFiscal
from fiscal.optimizer import Hypotheses, optimize
from fiscal.rules import load_rules

RULES = load_rules(2099, Path(__file__).parent / "fixtures")
ADULT = "2060-01-01"


def single(salaires, **kw) -> FoyerFiscal:
    decl = {"naissance": ADULT, "salaires": salaires, **kw.pop("decl", {})}
    return FoyerFiscal.model_validate(
        {"annee_revenus": 2099, "situation": "celibataire", "declarants": [decl], **kw})


def hyp(**kw) -> Hypotheses:
    base = {"annee_revenus": 2099, "budget": 20000, "taux_actualisation": "0.03",
            "risque_max": "modere", "blocage_max_ans": 15,
            "leviers": {"per": {"rendement": "0.03", "annees_avant_retraite": 10, "tmi_sortie": "0.11"},
                        "girardin_industriel": {"taux_reduction": "1.12"}}}
    base.update(kw)
    return Hypotheses.model_validate(base)


def alloc(plan):
    return {a.levier: a.montant for a in plan.allocations}


def test_per_first_then_girardin():
    # TMI 41 %: PER NPV/€ ~ 0.24 beats Girardin ~ 0.087; PER stops at its plafond.
    p = optimize(single(100000, decl={"per_plafond_disponible": 5000}), hyp(), RULES)
    assert alloc(p) == {"per": 5000, "girardin_industriel": 15000}
    assert p.economie_totale == 5000 * D("0.41") + 15000 * D("1.12")
    per = next(a for a in p.allocations if a.levier == "per")
    assert [s.economie_par_euro for s in per.segments] == [D("0.41")]


def test_lock_in_filter_and_tax_exhaustion():
    # PER locked 10 years > 5 allowed; Girardin stops when the réduction would exceed the tax.
    p = optimize(single(100000, decl={"per_plafond_disponible": 5000}), hyp(blocage_max_ans=5), RULES)
    assert alloc(p) == {"girardin_industriel": 19000}  # 21280 of réduction against 21300 of tax
    assert [e.levier for e in p.ecartes] == ["per"]


def test_no_tax_no_reduction():
    p = optimize(single(15000), hyp(), RULES)
    assert p.allocations == []


def test_bareme_option_chosen_when_cheaper():
    # TMI 11 %: 60 % of dividends at 11 % (+ lost décote) beats 12.8 % flat.
    f = single(25000, capitaux={"dividendes": 10000})
    p = optimize(f, hyp(budget=0, leviers={}), RULES)
    assert p.option_bareme is True
    assert (p.impot_initial, p.impot_final) == (2377, 2035)


def test_risk_filter():
    p = optimize(single(100000, decl={"per_plafond_disponible": 5000}), hyp(risque_max="faible"), RULES)
    assert p.allocations == [] and {e.levier for e in p.ecartes} == {"per", "girardin_industriel"}


def test_per_spills_into_dependant_plafond():
    f = single(100000, decl={"per_plafond_disponible": 2000}, vit_en_couple=True,
               personnes_a_charge=[{"naissance": "2080-01-01", "per_plafond_disponible": 3000}])
    p = optimize(f, hyp(leviers={"per": {"rendement": "0.03", "annees_avant_retraite": 10,
                                          "tmi_sortie": "0.11"}}), RULES)
    assert alloc(p) == {"per": 5000}


def test_per_step_split_across_plafonds():
    # 180 left on one plafond with 250 steps: the step must spill, never exceed a plafond.
    f = FoyerFiscal.model_validate({
        "annee_revenus": 2099, "situation": "marie", "declarants": [
            {"naissance": ADULT, "salaires": 150000, "per_plafond_disponible": 1180},
            {"naissance": ADULT, "salaires": 50000, "per_plafond_disponible": 1000}]})
    p = optimize(f, hyp(budget=5000, leviers={"per": {"rendement": "0.03", "annees_avant_retraite": 10,
                                                       "tmi_sortie": "0.11"}}), RULES)
    assert alloc(p) == {"per": 2180}
    assert len(p.allocations[0].segments) == 1  # one constant marginal rate, no wasted euro
