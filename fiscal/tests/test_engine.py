"""Mechanics tests against the synthetic 2099 rule set (hand-computed expectations)."""

from decimal import Decimal as D
from pathlib import Path

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from fiscal.diff import diff
from fiscal.engine import UnsupportedCase, compute
from fiscal.foyer import FoyerFiscal
from fiscal.rules import load_rules

RULES = load_rules(2099, Path(__file__).parent / "fixtures")
ADULT = "2060-01-01"  # 39 at the end of 2099: no age allowance


def foyer(**kw) -> FoyerFiscal:
    base = {"annee_revenus": 2099, "situation": "celibataire", "declarants": [{"naissance": ADULT}]}
    base.update(kw)
    return FoyerFiscal.model_validate(base)


def single(salaires, **kw):
    return foyer(declarants=[{"naissance": ADULT, "salaires": salaires}], **kw)


def test_single_bareme():
    r = compute(single(40000), RULES)
    # 40000 - 10 % = 36000 ; 20000*0.11 + 6000*0.30 = 4000
    assert (r.rni, r.droits_simples, r.decote, r.impot_net, r.tmi) == (36000, 4000, 0, 4000, D("0.30"))


def test_decote():
    r = compute(single(20000), RULES)
    # RNI 18000 => 880 ; décote 900 - 0.4525*880 = 501.8 => 502
    assert (r.droits_simples, r.decote, r.impot_net) == (880, 502, 378)


def test_qf_cap_couple_two_children():
    f = foyer(situation="marie",
              declarants=[{"naissance": ADULT, "salaires": 60000}, {"naissance": ADULT, "salaires": 40000}],
              personnes_a_charge=[{"naissance": "2090-01-01"}, {"naissance": "2092-01-01"}])
    r = compute(f, RULES)
    # 3 parts: 6600 ; 2 parts: 13400 - 2*1800 = 9800 => capped
    assert (r.parts, r.droits_simples) == (3, 9800)


def test_parent_isole_cap():
    r = compute(single(100000, personnes_a_charge=[{"naissance": "2090-01-01"}]), RULES)
    # 2 parts: 13400 ; 1 part: 21300 - 4200 = 17100
    assert (r.parts, r.droits_simples) == (2, 17100)


def test_garde_alternee_quarter_parts():
    f = single(30000, personnes_a_charge=[{"naissance": "2090-01-01", "garde_alternee": True}])
    assert compute(f, RULES).parts == D("1.5")  # 1 + 0.25 child + 0.25 case T


def test_niche_cap_clawback():
    f = single(100000, avantages=[{"dispositif": "emploi_domicile", "depenses": 30000},
                                  {"dispositif": "pinel", "reduction": 6000}])
    r = compute(f, RULES)
    # 21300 - 6000 Pinel + reprise (6000 + 6000 - 10000) - crédit 6000
    assert (r.reductions, r.credits, r.reprise_niches, r.impot_net) == (6000, 6000, 2000, 11300)


def test_girardin_counts_at_quote_part():
    f = single(100000, avantages=[{"dispositif": "pinel", "reduction": 9000},
                                  {"dispositif": "girardin_industriel", "reduction": 10000}])
    r = compute(f, RULES)
    # global 9000 ; majoré 4400 ; 9000 + 4400 <= 18000 => no claw-back
    assert r.reprise_niches == 0


def test_dons_cap_and_carry():
    f = single(100000, avantages=[{"dispositif": "dons", "interet_general": 20000, "aide_personnes": 1500}])
    r = compute(f, RULES)
    # 75 %: 1000 (500 overflows to 66 %) ; pool 20000+500 capped at 20 % * 90000 = 18000
    assert r.reductions == 750 + 11880
    assert [(d.annee, d.montant) for d in r.reports.dons] == [(2099, 2500)]


def test_pfu_vs_bareme():
    pfu = compute(single(40000, capitaux={"dividendes": 10000}), RULES)
    bar = compute(single(40000, capitaux={"dividendes": 10000, "option_bareme": True}), RULES)
    assert (pfu.impot_net, pfu.rfr) == (4000 + 1280, 46000)
    assert (bar.rni, bar.impot_net, bar.rfr) == (42000, 5800, 46000)
    assert bar.reports.csg_deductible == 680


def test_fonciers_deficit_global():
    f = single(40000, fonciers={"regime": "reel", "deficit_imputable_global": 10000,
                                "deficit_imputable_fonciers": 3000})
    r = compute(f, RULES)
    assert (r.rni, r.reports.deficit_foncier) == (26000, 3000)


def test_unsupported_is_loud():
    f = foyer(situation="veuf", personnes_a_charge=[{"naissance": "2090-01-01"}])
    with pytest.raises(UnsupportedCase):
        compute(f, RULES)


def test_diff_reports_changed_nodes():
    rows = {k: delta for k, _, _, delta in diff(compute(single(40000), RULES), compute(single(41000), RULES))}
    assert rows["impot_net.impot_net"] == 270  # 900 more RNI at 30 %


@settings(max_examples=300, deadline=None)
@given(st.integers(0, 400000), st.integers(1, 5000))
def test_tax_non_decreasing_in_income(sal, bump):
    assert compute(single(sal + bump), RULES).impot_net >= compute(single(sal), RULES).impot_net


def test_scolarite_reduction():
    r = compute(single(40000, avantages=[{"dispositif": "scolarite", "lycee": 1, "superieur": 1}]), RULES)
    assert r.reductions == 153 + 183


def test_exempt_overtime_only_in_rfr():
    f = foyer(declarants=[{"naissance": ADULT, "salaires": 40000, "heures_sup_exonerees": 2000}])
    r = compute(f, RULES)
    assert (r.rni, r.rfr) == (36000, 37800)  # overtime net of the 10 % allowance


def _couple_per(mutualisation):
    return foyer(situation="marie", per_mutualisation=mutualisation, declarants=[
        {"naissance": ADULT, "salaires": 60000, "per_versements": 8000, "per_plafond_disponible": 5000},
        {"naissance": ADULT, "salaires": 40000, "per_plafond_disponible": 4000}])


def test_per_plafond_per_declarant_unless_6qr():
    assert compute(_couple_per(False), RULES).rni == 90000 - 5000  # own plafond only
    assert compute(_couple_per(True), RULES).rni == 90000 - 8000  # pooled 9000 >= 8000


def test_dependant_per_own_plafond():
    f = single(40000, personnes_a_charge=[{"naissance": "2080-01-01", "per_versements": 3000,
                                           "per_plafond_disponible": 2500}], vit_en_couple=True)
    assert compute(f, RULES).rni == 36000 - 2500
