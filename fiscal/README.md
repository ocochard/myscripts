# fiscal: French income tax engine

Local-first French income tax engine (IR, contributions, prélèvements sociaux)
for one household, plus an optimizer that allocates a cash budget across tax levers. Python 3.12, Pydantic v2, Typer.

## Commands

```sh
python3 -m venv --system-site-packages .venv && .venv/bin/pip install --no-deps -e .
.venv/bin/fiscal compute foyer.yaml        # summary (+ --json for the full result)
.venv/bin/fiscal explain foyer.yaml        # every step with its legal references
.venv/bin/fiscal diff base.yaml scenario.yaml
.venv/bin/fiscal optimize foyer.yaml hypotheses.yaml   # see examples/hypotheses-2026.yaml
.venv/bin/fiscal ingest doc.pdf ...        # PDF -> text + type, into ~/.local/share/fiscal/inbox
.venv/bin/fiscal ingest --llm "$FISCAL_LLM_URL" doc.pdf   # + field extraction via a llama.cpp server
python3 -m pytest -q
```

FreeBSD dependencies come from packages: `py312-pydantic2 py312-typer
py312-hypothesis py312-pdfplumber py312-pytest py312-pyyaml poppler-utils`
(no `pydantic-core` wheel exists for FreeBSD on PyPI).

## Invariants

- **The engine is deterministic and the only source of tax numbers.** Any layer
  above it (optimizer, MCP, LLM) calls `engine.compute` and never re-derives tax.
- **Every legal value lives in `rules/ir/revenus-YYYY.yaml`**, keyed by *income*
  year (revenus 2025 = déclaration 2026 = LF 2026). Each section has `source`
  and `status`; `RuleSet.unverified()` surfaces anything not read in a DGFiP or
  BOFiP text, and the CLI prints it as a warning.
- **Unmodelled mechanisms raise `UnsupportedCase`**, never a silently wrong
  number (veuf with dependants, case P/W complementary réduction, CDHR above its
  threshold, micro above its threshold...).
- **Inputs mirror 2042 boxes** (comments in `foyer.py`), so a computation can be
  checked line by line against a filed return or an avis d'imposition. Unknown
  fields are rejected (`extra="forbid"`).
- **Liquidation order** follows the 2042 calculation sheet: QF cap -> décote ->
  réductions (capped at the barème tax) -> + PFU 12.8 % -> crédits -> niche-cap
  claw-back -> CEHR. Rounding to the nearest euro (CGI 193, 1657-1).
- **Personal data never enters the repo**, which is public: keep household files
  and documents outside it (e.g. `~/impots/`). `*.pdf`, `foyers/`, `private/`,
  `inbox/` are git-ignored as a safety net; ingest writes 0600 files under a
  0700 directory (`~/.local/share/fiscal/inbox`).

## Document types

`classify` recognises the avis d'impôt, the avis de situation déclarative, the
online return summary (`declaration_revenus`, form n° 2042), taxe foncière,
IFU, PER statements and payslips. The return summary prints one box per line
(`1AJ Salaires - Déclarant 1 : 45000`) and is parsed without any model by
`ingest/declaration.py` into a foyer draft (TODOs for what it does not carry,
unmapped boxes listed as comments).

## Field extraction (local LLM)

`ingest --llm` sends the numbered text of one document to the user's llama.cpp
server (LAN only, never a cloud API) under a closed JSON schema per document
type (`ingest/fields.py`). The model returns `(value, line)` pairs; `verify`
then requires the exact number to be printed on that line (`verifie`), or
uniquely elsewhere (`autre_ligne`), else the value is dropped (`introuvable`).
This rejects invented numbers, not mislabelled ones (a value read from the
wrong column of the right line passes), so extracts stay proposals for review.

## Optimizer

`optimizer.py` prices every candidate step with `engine.compute`, then turns
(amount, exact tax saving) into an NPV per lever from the user's assumptions
(PER = deferral taxed at exit, FCPI/FIP/PME = locked risky capital, SOFICA =
partial capital return, Girardin = cash that never comes back). Greedy by
marginal NPV per euro, re-evaluated after each step; PFU vs barème is
enumerated; risk and lock-in are hard filters. Payments made now count for the
*current* income year: `rules/ir/revenus-2026.yaml` is provisional (2025 values,
all `unverified`) until LF 2027 is enacted.

## Tests

- `tests/test_engine.py`: mechanics against a synthetic rule set
  (`tests/fixtures/revenus-2099.yaml`, round numbers, hand-computed results) plus
  a hypothesis property (tax non-decreasing in income).
- `tests/test_optimizer.py`: allocation order, filters, tax exhaustion, 2OP choice.
- `tests/test_golden_2025.py`: real 2025 rules against DGFiP's printed tax
  tables (Brochure IR 2026 p.372-375): ~170 cases across married, single,
  concubin, case T and case L. A new income year needs the same table check.
- A real household (file kept outside the repo) reproduces its avis 2026
  to the euro on parts, RBG, RNI, RFR and impôt net. The RFR counts exempt
  overtime net of the 10 % allowance: matched on that avis, not stated in the brochure.

## Not modelled yet

Feeding verified extracts into a foyer file (manual for now); OCR for scans; système du quotient (exceptional income); CDHR; CEHR lissage; case P/W
and veuf réductions complémentaires; dependants' own income; PER plafond
computation (taken from the avis); income-tax-exempt items of the RFR; foreign
income; carry-forwards other than dons, déficit foncier and déficit global.
