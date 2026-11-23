from fiscal.ingest import DocType, classify


def test_classify():
    assert classify("Revenu fiscal de référence 52 000\nImpôt sur le revenu net 3 100") == DocType.AVIS_IR
    assert classify("BULLETIN DE PAIE  Salaire brut 4 000  Net à payer 3 100") == DocType.BULLETIN_PAIE
    assert classify("Relevé annuel Plan d'Épargne Retraite - versements 2025") == DocType.RELEVE_PER
    assert classify("Imprimé fiscal unique 2025") == DocType.IFU
    assert classify("facture EDF") == DocType.INCONNU


DECL = """\
Déclaration des revenus 2025 - formulaire n° 2042
1AJ Salaires - Déclarant 1 : 52000
1BJ Salaires - Déclarant 2 : 31 500
1HH Heures supplémentaires et jours RTT - Déclarant 2 : 800
2TR Produits de placement à revenu fixe sans abattement : 1200
6NS Cotisations versées sur les nouveaux plan épargne retraite - Déc 1 : 4000
7EC Enfant scolarisé - Lycée - Nombre : 1
8HV RAS sur salaires et pensions - Déclarant 1 : 4100
9ZZ Case inconnue : 10
1AJ) Salaires - Déclarant 1
"""


def test_classify_new_types():
    assert classify(DECL) == DocType.DECLARATION_REVENUS
    assert classify("Avis de situation déclarative ... Revenu fiscal de référence 1") == DocType.AVIS_SITUATION
    assert classify("Revenu fiscal de référence 1\nImpôt sur le revenu net 2") == DocType.AVIS_IR
    assert classify("Avis de taxes foncières 2026") == DocType.TAXE_FONCIERE


def test_declaration_draft():
    from decimal import Decimal as D
    from fiscal.ingest.declaration import foyer_draft, parse_boxes

    boxes = parse_boxes(DECL)
    assert boxes["1BJ"].amount == D(31500) and "1AJ" in boxes
    draft, unmapped = foyer_draft(boxes, 2025)
    d1, d2 = draft["declarants"]
    assert (d1["salaires"], d2["salaires"], d2["heures_sup_exonerees"]) == (52000, 31500, 800)
    assert d1["per_plafond_disponible"].startswith("TODO")
    assert draft["avantages"] == [{"dispositif": "scolarite", "lycee": 1}]
    assert draft["prelevements"] == {"pas_preleve": 4100}
    assert unmapped == ["9ZZ Case inconnue (line 9)"]
