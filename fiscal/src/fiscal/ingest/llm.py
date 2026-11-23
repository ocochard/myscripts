"""Field extraction through a local llama.cpp server (OpenAI-compatible API).

The model only proposes (value, line number) pairs under a JSON schema; every
proposal is then checked against the text by `fields.verify`. Documents never
leave the LAN: the server URL is the user's own llama.cpp instance.
"""

from __future__ import annotations

import json
import urllib.request
from decimal import Decimal
from typing import Any, Protocol

from pydantic import BaseModel

from .extract import DocType
from .fields import SPECS, FieldSpec, verify

MAX_CHARS = 60_000  # ~20k tokens: an avis or a payslip is far below

SYSTEM = (
    "Tu extrais des valeurs d'un document fiscal ou de paie français. Le texte est fourni "
    "ligne par ligne, chaque ligne préfixée par son numéro puis '|'. Pour chaque champ demandé, "
    "donne la valeur numérique exacte telle qu'imprimée (sans arrondir, sans calcul) et le numéro "
    "de la ligne où elle est imprimée. Si le champ n'apparaît pas dans le document, mets null "
    "pour la valeur et la ligne. N'invente jamais une valeur."
)


class Completion(Protocol):
    def __call__(self, messages: list[dict], schema: dict) -> str: ...


class LlamaCpp:
    def __init__(self, url: str, timeout: float = 600, seed: int = 0) -> None:
        self.url = url.rstrip("/") + "/v1/chat/completions"
        self.timeout = timeout
        self.seed = seed

    def __call__(self, messages: list[dict], schema: dict) -> str:
        body = {
            "messages": messages,
            "temperature": 0,
            "seed": self.seed,
            "chat_template_kwargs": {"enable_thinking": False},
            "response_format": {"type": "json_schema", "json_schema": {"name": "extraction", "schema": schema}},
        }
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:  # noqa: S310 - user-configured URL
            data = json.load(resp)
        return data["choices"][0]["message"]["content"]


def schema_for(specs: list[FieldSpec]) -> dict[str, Any]:
    props = {
        s.key: {
            "type": "object",
            "properties": {"valeur": {"type": ["integer" if s.entier else "number", "null"]},
                           "ligne": {"type": ["integer", "null"]}},
            "required": ["valeur", "ligne"],
            "additionalProperties": False,
        }
        for s in specs
    }
    return {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}


class Champ(BaseModel):
    valeur: Decimal | None  # only set when the proposal was found in the text
    propose: Decimal | None  # what the model returned
    case_2042: str | None
    statut: str  # verifie | autre_ligne | introuvable | absent
    ligne: int | None
    texte: str | None  # the printed line, for review


class Extraction(BaseModel):
    type: DocType
    modele: str
    champs: dict[str, Champ]


def extract_fields(text: str, doc_type: DocType, complete: Completion, modele: str = "llama.cpp") -> Extraction:
    if doc_type not in SPECS:
        raise ValueError(f"no field list for document type {doc_type}")
    if len(text) > MAX_CHARS:
        raise ValueError(f"text is {len(text)} chars (> {MAX_CHARS}): not a single tax document?")
    specs = SPECS[doc_type]
    lines = text.splitlines()
    numbered = "\n".join(f"{i}|{ln.rstrip()}" for i, ln in enumerate(lines, 1) if ln.strip())
    wanted = "\n".join(f"- {s.key}: {s.description}" for s in specs)
    messages = [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": f"Champs à extraire :\n{wanted}\n\nDocument :\n{numbered}"},
    ]
    raw = json.loads(complete(messages, schema_for(specs)), parse_float=Decimal)
    champs: dict[str, Champ] = {}
    for s in specs:
        item = raw.get(s.key) or {}
        val = item.get("valeur")
        if val is None:
            champs[s.key] = Champ(valeur=None, propose=None, case_2042=s.case, statut="absent",
                                  ligne=None, texte=None)
            continue
        val = Decimal(val)
        statut, ligne = verify(val, item.get("ligne"), lines)
        champs[s.key] = Champ(valeur=val if statut != "introuvable" else None, propose=val,
                              case_2042=s.case, statut=statut,
                              ligne=ligne, texte=lines[ligne - 1].strip() if ligne else None)
    return Extraction(type=doc_type, modele=modele, champs=champs)
