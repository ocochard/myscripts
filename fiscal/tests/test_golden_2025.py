"""Golden tests: real 2025 rules against DGFiP's own tax tables.

Source: Brochure pratique IR 2026, "Barème de l'impôt sur les revenus de 2025",
p.372-375. The tables give the tax after QF cap and décote, by revenu imposable
and number of parts.
"""

from decimal import Decimal as D

import pytest

from fiscal.engine import compute
from fiscal.foyer import FoyerFiscal
from fiscal.rules import Status, load_rules

R = load_rules(2025)
KID = {"naissance": "2015-06-01"}
KID_INV = {**KID, "invalide": True}


def _foyer(rni: int, situation: str, pac: list, **kw) -> FoyerFiscal:
    n = 2 if situation == "marie" else 1
    # frais réels = 0 makes the RNI equal to the salary.
    decl = [{"naissance": "1985-01-01", "salaires": rni if i == 0 else 0, "frais_reels": 0} for i in range(n)]
    return FoyerFiscal.model_validate(
        {"annee_revenus": 2025, "situation": situation, "declarants": decl, "personnes_a_charge": pac, **kw})


def _tax(f: FoyerFiscal) -> tuple[D, D]:
    r = compute(f, R)
    return r.parts, r.droits_simples - r.decote


# Dependants giving each part count in each table.
MARIE = [[], [KID], [KID, KID], [KID, KID_INV], [KID, KID, KID], [KID, KID, KID_INV], [KID] * 4]
SEUL = [[], [KID], [KID, KID], [KID, KID_INV], [KID] * 3, [KID, KID, KID_INV], [KID] * 4,
        [KID, KID, KID, KID_INV], [KID] * 5]
PARENT_ISOLE = [[KID], [KID, KID], [KID, KID_INV], [KID] * 3, [KID, KID, KID_INV], [KID] * 4,
                [KID, KID, KID, KID_INV]]

TABLES = {
    # "MARIÉS OU PACSÉS", 2 .. 5 parts
    ("marie", False): (MARIE, [D(2) + D("0.5") * i for i in range(7)], {
        33000: [83, 0, 0, 0, 0, 0, 0],
        38500: [962, 35, 0, 0, 0, 0, 0],
        50000: [2799, 1872, 946, 19, 0, 0, 0],
        60000: [4208, 3410, 2543, 1617, 690, 0, 0],
        88000: [12608, 10801, 8994, 7187, 5380, 3938, 3300],
        100000: [16208, 14401, 12594, 10787, 8980, 7173, 5366],
        120000: [22208, 20401, 18594, 16787, 14980, 13173, 11366],
        175000: [39351, 37544, 35737, 33930, 32123, 30316, 28509],
        225000: [59851, 58044, 56237, 54430, 52623, 50816, 49009],
    }),
    # "PERSONNES SEULES / CÉLIBATAIRES OU DIVORCÉS CONCUBINS", 1 .. 5 parts (no case T)
    ("celibataire", True): (SEUL, [D(1) + D("0.5") * i for i in range(9)], {
        17213: [0] * 9,
        17214: [1] + [0] * 8,
        20000: [445] + [0] * 8,
        30000: [2104, 1116, 189, 0, 0, 0, 0, 0, 0],
        50000: [8104, 6297, 4490, 2683, 1532, 605, 0, 0, 0],
        60000: [11104, 9297, 7490, 5683, 3876, 2134, 1276, 349, 0],
        100000: [24801, 22994, 21187, 19380, 17573, 15766, 13959, 12152, 10345],
        200000: [66524, 64717, 62910, 61103, 59296, 57489, 55682, 53875, 52068],
    }),
    # "CÉLIBATAIRES OU DIVORCÉS élevant seuls leur(s) enfant(s)", 2 .. 5 parts (case T)
    ("celibataire", False): (PARENT_ISOLE, [D(2) + D("0.5") * i for i in range(7)], {
        30000: [189, 0, 0, 0, 0, 0, 0],
        50000: [3842, 2310, 1532, 605, 0, 0, 0],
        60000: [6842, 5035, 3228, 2134, 1276, 349, 0],
        100000: [20539, 18732, 16925, 15118, 13311, 11504, 9697],
        200000: [62262, 60455, 58648, 56841, 55034, 53227, 51420],
    }),
}

CASES = [
    pytest.param(sit, couple_flag, pac, parts, rni, tax, id=f"{sit}{'-concubin' if couple_flag else ''}-{parts}p-{rni}")
    for (sit, couple_flag), (pacs, parts_list, rows) in TABLES.items()
    for rni, taxes in rows.items()
    for pac, parts, tax in zip(pacs, parts_list, taxes)
]


@pytest.mark.parametrize("situation,concubin,pac,parts,rni,expected", CASES)
def test_dgfip_table(situation, concubin, pac, parts, rni, expected):
    kw = {"vit_en_couple": True} if concubin else {}
    got_parts, tax = _tax(_foyer(rni, situation, pac, **kw))
    assert (got_parts, tax) == (parts, expected)


@pytest.mark.parametrize("rni,expected", [(23013, 0), (23014, 1), (23500, 78), (30000, 1116),
                                          (50000, 7025), (100000, 23722), (200000, 65445)])
def test_dgfip_table_case_l(rni, expected):
    """Table 'personnes seules ayant un enfant majeur élevé seules (case L)', 1.5 parts."""
    assert _tax(_foyer(rni, "celibataire", [], case_l=True)) == (D("1.5"), expected)



def test_rule_statuses():
    assert R.recouvrement.status == Status.UNVERIFIED  # 8 € refund threshold not confirmed
    assert R.unverified() == ["recouvrement"]
