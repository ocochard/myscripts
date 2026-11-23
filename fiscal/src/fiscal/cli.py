"""Command line: compute, diff, explain, ingest."""

from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path
from typing import Annotated

import typer

from .diff import diff as diff_results
from .engine import Resultat, compute as engine_compute
from .foyer import FoyerFiscal
from .ingest.extract import DocType
from .money import load_yaml
from .rules import load_rules

app = typer.Typer(no_args_is_help=True, add_completion=False)

DEFAULT_INBOX = Path.home() / ".local" / "share" / "fiscal" / "inbox"

SUMMARY = ["parts", "rbg", "rni", "tmi", "droits_simples", "decote", "reductions",
           "impot_proportionnel", "credits", "reprise_niches", "rfr", "cehr",
           "impot_net", "prelevements_sociaux", "solde_ir"]


def _run(path: Path) -> Resultat:
    foyer = FoyerFiscal.model_validate(load_yaml(path))
    return engine_compute(foyer, load_rules(foyer.annee_revenus))


def _fmt(v: object) -> str:
    if isinstance(v, Decimal):
        return f"{v.normalize():f}" if v == v.to_integral() else f"{v:.4f}".rstrip("0")
    return str(v)


@app.command()
def compute(foyer: Path, as_json: Annotated[bool, typer.Option("--json")] = False) -> None:
    """Compute IR, contributions and PS for a foyer YAML file."""
    r = _run(foyer)
    if as_json:
        typer.echo(json.dumps(r.model_dump(mode="json"), indent=2, ensure_ascii=False))
        return
    for k in SUMMARY:
        typer.echo(f"{k:22} {_fmt(getattr(r, k))}")
    rep = r.reports
    typer.echo(f"{'reports N+1':22} deficit_foncier={rep.deficit_foncier} deficit_global={rep.deficit_global} "
               f"csg_deductible={rep.csg_deductible} dons={[(d.annee, str(d.montant)) for d in rep.dons]}")
    for w in r.warnings:
        typer.echo(f"warning: {w}", err=True)


@app.command()
def explain(foyer: Path) -> None:
    """Print every step of the computation with the legal references used."""
    r = _run(foyer)
    for s in r.steps:
        typer.echo(f"[{s.name}]  {'; '.join(s.refs)}")
        for k, v in s.values.items():
            typer.echo(f"    {k:28} {_fmt(v)}")
    for w in r.warnings:
        typer.echo(f"warning: {w}", err=True)


@app.command()
def diff(base: Path, scenario: Path) -> None:
    """Show which computation nodes change between two foyer files."""
    for key, a, b, delta in diff_results(_run(base), _run(scenario)):
        d = "" if delta is None else f"  ({'+' if delta > 0 else ''}{_fmt(delta)})"
        typer.echo(f"{key:50} {_fmt(a):>12} -> {_fmt(b):>12}{d}")


@app.command()
def optimize(foyer: Path, hypotheses: Path, as_json: Annotated[bool, typer.Option("--json")] = False) -> None:
    """Allocate a cash budget across tax levers by net present value under your assumptions."""
    from .optimizer import Hypotheses, optimize as run

    f = FoyerFiscal.model_validate(load_yaml(foyer))
    h = Hypotheses.model_validate(load_yaml(hypotheses))
    p = run(f, h, load_rules(f.annee_revenus))
    if as_json:
        typer.echo(json.dumps(p.model_dump(mode="json"), indent=2, ensure_ascii=False))
        return
    typer.echo(f"option barème (2OP)    {p.option_bareme}")
    typer.echo(f"impôt + PS             {_fmt(p.impot_initial)} -> {_fmt(p.impot_final)}  "
               f"(économie {_fmt(p.economie_totale)}, cash engagé {_fmt(p.cash_engage)}, "
               f"VAN {_fmt(p.van_totale.quantize(Decimal(1)))})")
    for a in p.allocations:
        typer.echo(f"  {a.levier:20} {_fmt(a.montant):>8}  économie {_fmt(a.economie_impot):>7}  "
                   f"VAN {_fmt(a.van.quantize(Decimal(1))):>7}  blocage {a.blocage_ans} ans  risque {a.risque}")
        for s in a.segments:
            typer.echo(f"      {_fmt(s.de):>8} .. {_fmt(s.a):>8}  {_fmt(s.economie_par_euro)} €/€")
    for k, (sav, van) in p.premier_euro.items():
        typer.echo(f"  premier pas {k:20} économie {sav:.2f} €/€  VAN {van:.3f} €/€")
    for e in p.ecartes:
        typer.echo(f"  écarté {e.levier:20} {e.raison}")
    if p.alternative:
        typer.echo(f"  alternative 2OP={bool(p.alternative['option_bareme'])}: "
                   f"VAN {_fmt(p.alternative['van_totale'].quantize(Decimal(1)))}")
    for w in p.avertissements:
        typer.echo(f"warning: {w}", err=True)


@app.command()
def ingest(
    pdfs: list[Path],
    out: Annotated[Path, typer.Option(help="private output directory")] = DEFAULT_INBOX,
    llm: Annotated[str | None, typer.Option(envvar="FISCAL_LLM_URL",
                                            help="llama.cpp server URL: propose and verify fields")] = None,
    doc_type: Annotated[DocType | None, typer.Option("--type", help="override the detected type")] = None,
) -> None:
    """Extract text from PDFs, classify them, and optionally extract fields with a local LLM."""
    import yaml

    from .ingest import ingest as do_ingest
    from .ingest.llm import LlamaCpp

    complete = LlamaCpp(llm) if llm else None
    for pdf in pdfs:
        doc = do_ingest(pdf, out, complete, doc_type, modele=llm or "")
        typer.echo(f"{doc.type:14} {doc.pages:3}p  {pdf} -> {doc.text_file}")
        if doc.extract_file and doc.type == DocType.DECLARATION_REVENUS:
            typer.echo(f"    -> {doc.extract_file}  (foyer draft: fill the TODOs)")
        elif doc.extract_file:
            ex = yaml.safe_load(Path(doc.extract_file).read_text(encoding="utf-8"))
            for key, c in ex["champs"].items():
                shown = c["valeur"] if c["valeur"] is not None else c["propose"]
                case = f"[{c['case_2042']}]" if c["case_2042"] else ""
                typer.echo(f"    {key:36} {str(shown):>12} {case:6} {c['statut']:12} "
                           f"{('L' + str(c['ligne'])) if c['ligne'] else ''}")
            typer.echo(f"    -> {doc.extract_file}  (review before use)")


if __name__ == "__main__":
    app()
