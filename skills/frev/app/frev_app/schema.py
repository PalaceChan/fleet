"""Review and submission shapes (v1) and their validation.

Everything the browser shows is validated here before it is published, and
everything the browser sends is validated here before it is stored.  Phases are
review labels, not Fleet task states.  Validation returns a list of error
strings (empty when valid) so callers can show all problems at once.
"""

from __future__ import annotations

import json
import re

REVIEW_VERSION = 1

PHASES = ("decision", "active", "waiting", "blocked", "done", "deferred", "unknown", "ready")
"""Review classifications, ordered roughly by urgency; never native Fleet enums."""

DISPOSITIONS = ("applied", "noted", "needs-clarification", "waiting", "declined", "failed", "uncertain")
"""How the commander accounted for one input.  ``planned`` is deliberately absent:
a published revision must not leave an input unaccounted for."""

INPUT_TYPES = ("choice", "comment", "message")
SUBMISSION_KINDS = ("feedback", "end")

ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$")
TEXT_LIMIT = 20_000
ITEM_LIMIT = 200
INPUT_LIMIT = 200

REVIEW_KEYS = {"version", "title", "summary", "items", "dispositions", "note"}
ITEM_KEYS = {"id", "title", "owner", "phase", "summary", "body", "choices", "attention", "source_refs", "depends_on"}
CHOICE_KEYS = {"id", "question", "options", "recommendation"}
OPTION_KEYS = {"id", "label"}
DISPOSITION_KEYS = {"input_id", "status", "note"}
SUBMISSION_KEYS = {"id", "revision", "kind", "inputs", "client"}
INPUT_KEYS = {"id", "type", "choice_id", "option_id", "anchor_id", "text"}


class ValidationError(ValueError):
    """Raised by ``*_or_raise`` helpers; ``errors`` lists every problem found."""

    def __init__(self, errors):
        super().__init__("; ".join(errors))
        self.errors = list(errors)


def _is_id(v) -> bool:
    return isinstance(v, str) and bool(ID_RE.match(v))


def _nonblank(v) -> bool:
    return isinstance(v, str) and v.strip() != ""


def _text_ok(v) -> bool:
    return isinstance(v, str) and len(v) <= TEXT_LIMIT


def _unknown_keys(obj: dict, allowed: set, where: str, errors: list) -> None:
    extra = sorted(set(obj) - allowed)
    if extra:
        errors.append(f"{where}: unknown keys {extra}")


def parse_strict(text: str):
    """Parse JSON rejecting duplicate object keys (the last-wins default hides mistakes)."""

    def no_dupes(pairs):
        obj = {}
        for k, v in pairs:
            if k in obj:
                raise ValueError(f"duplicate key {k!r}")
            obj[k] = v
        return obj

    return json.loads(text, object_pairs_hook=no_dupes)


# ---------------------------------------------------------------- review


def validate_review(review) -> list:
    """Errors in REVIEW (a parsed JSON value); empty list when valid."""
    errors: list = []
    if not isinstance(review, dict):
        return ["review must be a JSON object"]
    _unknown_keys(review, REVIEW_KEYS, "review", errors)
    if review.get("version") != REVIEW_VERSION:
        errors.append(f"review.version must be {REVIEW_VERSION}")
    if not _nonblank(review.get("title")):
        errors.append("review.title must be a non-empty string")
    if not _nonblank(review.get("summary")) or not _text_ok(review.get("summary")):
        errors.append("review.summary must be a non-empty string")
    if "note" in review and not (_text_ok(review["note"])):
        errors.append("review.note must be a string")
    items = review.get("items")
    if not isinstance(items, list):
        errors.append("review.items must be a list")
        items = []
    if len(items) > ITEM_LIMIT:
        errors.append(f"review.items: more than {ITEM_LIMIT} items")
    ids: dict = {}
    item_ids: set = set()
    for i, item in enumerate(items):
        where = f"items[{i}]"
        if not isinstance(item, dict):
            errors.append(f"{where}: must be an object")
            continue
        _unknown_keys(item, ITEM_KEYS, where, errors)
        iid = item.get("id")
        if not _is_id(iid):
            errors.append(f"{where}.id: missing or not a safe id")
        elif iid in ids:
            errors.append(f"{where}.id: duplicate id {iid!r} (items and choices share one namespace)")
        else:
            ids[iid] = "item"
            item_ids.add(iid)
        for key in ("title", "owner", "summary"):
            if not _nonblank(item.get(key)) or not _text_ok(item.get(key)):
                errors.append(f"{where}.{key}: must be a non-empty string")
        if not _text_ok(item.get("body", "")):
            errors.append(f"{where}.body: must be a string of at most {TEXT_LIMIT} characters")
        if item.get("phase") not in PHASES:
            errors.append(f"{where}.phase: must be one of {list(PHASES)}")
        if "attention" in item and not _text_ok(item["attention"]):
            errors.append(f"{where}.attention: must be a string")
        for key in ("source_refs", "depends_on"):
            if key in item and not (isinstance(item[key], list) and all(isinstance(s, str) for s in item[key])):
                errors.append(f"{where}.{key}: must be a list of strings")
        choices = item.get("choices", [])
        if not isinstance(choices, list):
            errors.append(f"{where}.choices: must be a list")
            choices = []
        for j, choice in enumerate(choices):
            cwhere = f"{where}.choices[{j}]"
            if not isinstance(choice, dict):
                errors.append(f"{cwhere}: must be an object")
                continue
            _unknown_keys(choice, CHOICE_KEYS, cwhere, errors)
            cid = choice.get("id")
            if not _is_id(cid):
                errors.append(f"{cwhere}.id: missing or not a safe id")
            elif cid in ids:
                errors.append(f"{cwhere}.id: duplicate id {cid!r} (items and choices share one namespace)")
            else:
                ids[cid] = "choice"
            if not _nonblank(choice.get("question")) or not _text_ok(choice.get("question")):
                errors.append(f"{cwhere}.question: must be a non-empty string")
            options = choice.get("options")
            if not isinstance(options, list) or len(options) < 2:
                errors.append(f"{cwhere}.options: at least two options are required")
                options = []
            oids: set = set()
            for k, opt in enumerate(options):
                owhere = f"{cwhere}.options[{k}]"
                if not isinstance(opt, dict):
                    errors.append(f"{owhere}: must be an object")
                    continue
                _unknown_keys(opt, OPTION_KEYS, owhere, errors)
                oid = opt.get("id")
                if not _is_id(oid):
                    errors.append(f"{owhere}.id: missing or not a safe id")
                elif oid in oids:
                    errors.append(f"{owhere}.id: duplicate option id {oid!r}")
                else:
                    oids.add(oid)
                if not _nonblank(opt.get("label")) or not _text_ok(opt.get("label")):
                    errors.append(f"{owhere}.label: must be a non-empty string")
            if "recommendation" in choice and choice["recommendation"] not in oids:
                errors.append(f"{cwhere}.recommendation: must name one of the option ids")
    for i, item in enumerate(items):
        if isinstance(item, dict):
            for dep in item.get("depends_on", []) if isinstance(item.get("depends_on", []), list) else []:
                if dep not in item_ids:
                    errors.append(f"items[{i}].depends_on: unknown item {dep!r}")
    dispositions = review.get("dispositions", [])
    if not isinstance(dispositions, list):
        errors.append("review.dispositions must be a list")
        dispositions = []
    seen_inputs: set = set()
    for i, d in enumerate(dispositions):
        where = f"dispositions[{i}]"
        if not isinstance(d, dict):
            errors.append(f"{where}: must be an object")
            continue
        _unknown_keys(d, DISPOSITION_KEYS, where, errors)
        if not _is_id(d.get("input_id")):
            errors.append(f"{where}.input_id: missing or not a safe id")
        elif d["input_id"] in seen_inputs:
            errors.append(f"{where}.input_id: duplicate {d['input_id']!r}")
        else:
            seen_inputs.add(d["input_id"])
        if d.get("status") not in DISPOSITIONS:
            errors.append(f"{where}.status: must be one of {list(DISPOSITIONS)}")
        if not _nonblank(d.get("note")) or not _text_ok(d.get("note")):
            errors.append(f"{where}.note: must be a non-empty string")
    return errors


def validate_review_or_raise(review) -> dict:
    errors = validate_review(review)
    if errors:
        raise ValidationError(errors)
    return review


def needs_you(item: dict) -> bool:
    """Needs-you rule: any choice, phase ``decision`` or a non-blank ``attention``."""
    return bool(item.get("choices")) or item.get("phase") == "decision" or _nonblank(item.get("attention", ""))


def review_index(review: dict) -> dict:
    """Lookup tables for a valid review: item ids, choice id -> (item id, option ids)."""
    items = {item["id"]: item for item in review.get("items", [])}
    choices = {}
    for item in review.get("items", []):
        for choice in item.get("choices", []):
            choices[choice["id"]] = (item["id"], {o["id"] for o in choice["options"]})
    return {"items": items, "choices": choices}


# ---------------------------------------------------------------- submission


def validate_submission(submission, review) -> list:
    """Errors in SUBMISSION against the exact published REVIEW it targets."""
    errors: list = []
    if not isinstance(submission, dict):
        return ["submission must be a JSON object"]
    _unknown_keys(submission, SUBMISSION_KEYS, "submission", errors)
    if not _is_id(submission.get("id")):
        errors.append("submission.id: missing or not a safe id")
    if not isinstance(submission.get("revision"), int) or isinstance(submission.get("revision"), bool):
        errors.append("submission.revision: must be an integer")
    kind = submission.get("kind", "feedback")
    if kind not in SUBMISSION_KINDS:
        errors.append(f"submission.kind: must be one of {list(SUBMISSION_KINDS)}")
    if "client" in submission and not (isinstance(submission["client"], str) and len(submission["client"]) <= 200):
        errors.append("submission.client: must be a short string")
    inputs = submission.get("inputs")
    if not isinstance(inputs, list):
        errors.append("submission.inputs: must be a list")
        inputs = []
    if len(inputs) > INPUT_LIMIT:
        errors.append(f"submission.inputs: more than {INPUT_LIMIT} inputs")
    if kind == "feedback" and not inputs:
        errors.append("submission.inputs: a feedback round needs at least one input")
    index = review_index(review) if isinstance(review, dict) else {"items": {}, "choices": {}}
    seen: set = set()
    picked: set = set()
    for i, inp in enumerate(inputs):
        where = f"inputs[{i}]"
        if not isinstance(inp, dict):
            errors.append(f"{where}: must be an object")
            continue
        _unknown_keys(inp, INPUT_KEYS, where, errors)
        iid = inp.get("id")
        if not _is_id(iid):
            errors.append(f"{where}.id: missing or not a safe id")
        elif iid in seen:
            errors.append(f"{where}.id: duplicate input id {iid!r}")
        else:
            seen.add(iid)
        typ = inp.get("type")
        if typ not in INPUT_TYPES:
            errors.append(f"{where}.type: must be one of {list(INPUT_TYPES)}")
            continue
        if typ == "choice":
            cid = inp.get("choice_id")
            if cid not in index["choices"]:
                errors.append(f"{where}.choice_id: {cid!r} is not a choice of this revision")
            else:
                if inp.get("option_id") not in index["choices"][cid][1]:
                    errors.append(f"{where}.option_id: {inp.get('option_id')!r} is not an option of choice {cid!r}")
                if cid in picked:
                    errors.append(f"{where}: more than one pick for choice {cid!r}")
                picked.add(cid)
            if "text" in inp and not _text_ok(inp["text"]):
                errors.append(f"{where}.text: too long")
        else:
            if not _nonblank(inp.get("text")) or not _text_ok(inp.get("text")):
                errors.append(f"{where}.text: must be a non-empty string of at most {TEXT_LIMIT} characters")
            if typ == "comment" and inp.get("anchor_id") not in index["items"]:
                errors.append(f"{where}.anchor_id: {inp.get('anchor_id')!r} is not an item of this revision")
            if typ == "message" and "anchor_id" in inp:
                errors.append(f"{where}.anchor_id: a message has no anchor")
    return errors


def validate_submission_or_raise(submission, review) -> dict:
    errors = validate_submission(submission, review)
    if errors:
        raise ValidationError(errors)
    return submission


def missing_dispositions(review: dict, submission: dict) -> list:
    """Input ids of SUBMISSION that REVIEW's dispositions do not account for."""
    have = {d["input_id"] for d in review.get("dispositions", [])}
    return [inp["id"] for inp in submission.get("inputs", []) if inp["id"] not in have]


EXAMPLE_REVIEW = {
    "version": 1,
    "title": "workshop — next useful moves",
    "summary": "Navigation is nearly ready; choose the test scope before the frontend handoff. Nothing is blocked.",
    "note": "First revision of this session.",
    "items": [
        {
            "id": "navigation",
            "title": "Keyboard navigation",
            "owner": "frontend",
            "phase": "waiting",
            "summary": "Reported ready; a test pass is needed before the PR is opened.",
            "body": "The focused pass covers settings only. The broader pass also covers account navigation.\n\n"
                    "Evidence: task `navigation` reported done at 09:40; verification pending.",
            "source_refs": ["task:navigation"],
            "choices": [
                {
                    "id": "navigation-tests",
                    "question": "Which test pass should frontend run before opening the navigation PR?",
                    "options": [
                        {"id": "focused", "label": "Settings tests only, then open the PR (do not merge)"},
                        {"id": "broader", "label": "Settings and account navigation, then open the PR (do not merge)"},
                    ],
                    "recommendation": "focused",
                }
            ],
        },
        {
            "id": "release-note",
            "title": "Release note draft",
            "owner": "commander",
            "phase": "done",
            "summary": "The requested draft is complete.",
            "body": "Draft at `tasks/…/report.md`. Publication has not been requested.",
            "attention": "Read the draft wording before it goes anywhere.",
        },
        {
            "id": "query-cache",
            "title": "Query cache",
            "owner": "backend",
            "phase": "deferred",
            "summary": "Suspended by park; no resume requested.",
            "body": "",
        },
    ],
}
