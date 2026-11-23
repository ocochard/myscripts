"""LLM extraction: verification logic with a fake model (no network)."""

import json
from decimal import Decimal as D

from fiscal.ingest import DocType
from fiscal.ingest.fields import numbers, verify
from fiscal.ingest.llm import extract_fields, schema_for
from fiscal.ingest.fields import SPECS

AVIS = """\
                    AVIS D'IMPÔT 2026 SUR LES REVENUS DE L'ANNÉE 2025
Nombre de parts                                   2,5
Revenu brut global                             98 420
Revenu imposable                               92 420
Revenu fiscal de référence                    104 720
Impôt sur le revenu net                        10 934
"""


def test_numbers_french_format():
    assert numbers("Revenu fiscal de référence   104 720") == {D(104720)}
    assert numbers("Net imposable 3 512,47 €  cumul 38.637,17") == {D("3512.47"), D("38637.17")}
    assert numbers("Nombre de parts 2,5") == {D("2.5")}
    assert numbers("Impot preleve a la source   -538,40") == {D("538.40")}


def test_verify_statuses():
    lines = AVIS.splitlines()
    assert verify(D(104720), 5, lines) == ("verifie", 5)
    assert verify(D(104720), 2, lines) == ("autre_ligne", 5)  # wrong line, unique elsewhere
    assert verify(D(999999), 5, lines) == ("introuvable", None)  # hallucinated


def test_schema_is_closed():
    s = schema_for(SPECS[DocType.AVIS_IR])
    assert s["additionalProperties"] is False and set(s["required"]) == {f.key for f in SPECS[DocType.AVIS_IR]}


def test_extract_with_fake_model():
    def fake(messages, schema):
        assert "4|Revenu imposable" in messages[1]["content"]  # numbered lines reach the model
        out = {k: {"valeur": None, "ligne": None} for k in schema["properties"]}
        out["revenu_fiscal_reference"] = {"valeur": 104720, "ligne": 5}
        out["nombre_parts"] = {"valeur": 2.5, "ligne": 2}
        out["impot_net"] = {"valeur": 10943, "ligne": 6}  # digit swap: must be rejected
        return json.dumps(out)

    ex = extract_fields(AVIS, DocType.AVIS_IR, fake)
    c = ex.champs
    assert (c["revenu_fiscal_reference"].valeur, c["revenu_fiscal_reference"].statut) == (104720, "verifie")
    assert c["nombre_parts"].valeur == D("2.5")
    assert (c["impot_net"].valeur, c["impot_net"].propose, c["impot_net"].statut) == (None, 10943, "introuvable")
    assert c["salaires_declarant1"].statut == "absent"
