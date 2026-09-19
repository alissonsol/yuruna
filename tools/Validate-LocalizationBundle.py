#!/usr/bin/env python3
"""Check an exported localization bundle offline without changing its files."""
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.

import argparse
import csv
import datetime
import hashlib
import io
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath

EXPECTED_VALIDATION_SHA256 = "@@VALIDATION_SHA256@@"
XML_NAMESPACE = "urn:oasis:names:tc:xliff:document:2.0"


def fail(message):
    raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail("Duplicate JSON member: " + key)
        result[key] = value
    return result


def read_json(text):
    return json.loads(text, object_pairs_hook=unique_object,
                      parse_constant=lambda value: fail("Invalid JSON number: " + value))


def bundle_path(root, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative or ":" in relative:
        fail("Invalid bundle path: " + repr(relative))
    path = PurePosixPath(relative)
    if path.is_absolute() or any(part in ("", ".", "..") for part in relative.split("/")):
        fail("Unconfined bundle path: " + relative)
    target = root
    for part in path.parts:
        target = target / part
        if target.is_symlink():
            fail("Linked bundle path: " + relative)
    return target


def read_text(path):
    return path.read_bytes().decode("utf-8-sig")


def validate_schema(value, schema, root=None, location="document"):
    """Apply only the bounded keyword set used by the bundled exchange schemas."""
    root = schema if root is None else root
    supported = {"$schema", "$id", "title", "description", "definitions", "$ref",
                 "type", "required", "additionalProperties", "properties", "const",
                 "enum", "pattern", "minLength", "items", "minItems"}
    if set(schema) - supported:
        fail("Unsupported validation schema keywords")
    if "$ref" in schema:
        reference = schema["$ref"]
        if not reference.startswith("#/definitions/"):
            fail("Only bundled schema definitions are supported")
        validate_schema(value, root["definitions"][reference.split("/")[-1]], root, location)
        return
    kinds = {"object": dict, "array": list, "string": str}
    if "type" in schema and (schema["type"] not in kinds or not isinstance(value, kinds[schema["type"]])):
        fail(location + ": expected " + str(schema["type"]))
    if "const" in schema and value != schema["const"]:
        fail(location + ": invalid constant")
    if "enum" in schema and value not in schema["enum"]:
        fail(location + ": unknown value")
    if isinstance(value, dict):
        missing = set(schema.get("required", [])) - set(value)
        if missing:
            fail(location + ": missing " + ", ".join(sorted(missing)))
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False and set(value) - set(properties):
            fail(location + ": unknown properties")
        for key, child in value.items():
            if key in properties:
                validate_schema(child, properties[key], root, location + "." + key)
    elif isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            fail(location + ": too few rows")
        for index, child in enumerate(value):
            if "items" in schema:
                validate_schema(child, schema["items"], root, location + "[" + str(index) + "]")
    elif isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            fail(location + ": empty value")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            fail(location + ": invalid value")


def read_entries(path, format_name, locale):
    text = read_text(path)
    if format_name == "Json":
        payload = read_json(text)
        if not isinstance(payload, dict) or payload.get("locale") != locale or not isinstance(payload.get("entries"), list):
            fail(str(path) + ": expected this locale's JSON entries")
        return payload["entries"]
    if format_name == "Csv":
        reader = csv.DictReader(io.StringIO(text, newline=""), strict=True)
        fields = reader.fieldnames or []
        if len(fields) != len(set(fields)) or not {"id", "english", "translation"}.issubset(fields):
            fail(str(path) + ": invalid CSV columns")
        result = list(reader)
        if any(None in row or any(value is None for value in row.values()) for row in result):
            fail(str(path) + ": inconsistent CSV column count")
        return result
    if format_name != "Xliff":
        fail("Unsupported interchange format: " + str(format_name))
    if re.search(r"<!\s*(?:DOCTYPE|ENTITY)\b", text, re.I):
        fail("XLIFF must not contain DTDs or entity declarations")
    document = ET.fromstring(text)
    prefix = "{" + XML_NAMESPACE + "}"
    if document.tag != prefix + "xliff" or document.get("version") != "2.0":
        fail("Expected XLIFF 2.0 in its declared namespace")
    if document.get("srcLang") != "en-US" or document.get("trgLang") != locale:
        fail("XLIFF language identity differs from the request")
    files = list(document)
    if len(files) != 1 or files[0].tag != prefix + "file":
        fail("Expected one XLIFF file")
    result = []
    for unit in files[0]:
        if unit.tag != prefix + "unit" or len(unit) != 1 or unit[0].tag != prefix + "segment":
            fail("Expected one segment per XLIFF unit")
        children = list(unit[0])
        if [child.tag for child in children] != [prefix + "source", prefix + "target"]:
            fail("XLIFF segment requires one source and one target")
        if any(len(child) for child in children):
            fail("This exchange uses plain XLIFF text, without inline elements")
        result.append({"id": unit.get("id"), "english": children[0].text or "",
                       "translation": children[1].text or ""})
    return result


def validate_message(text, contract, row_id):
    if contract["kind"] == "message":
        forms = [text]
    else:
        variants = read_json(text)
        if not isinstance(variants, dict) or set(variants) != set(contract["variants"]):
            fail(row_id + ": translated variant names differ from the request")
        forms = list(variants.values())
    used = {contract["selector"]} if contract["selector"] else set()
    for form in forms:
        if not isinstance(form, str) or not form.strip():
            fail(row_id + ": empty or nontext translated form")
        used.update(re.findall(r"\{([A-Za-z][A-Za-z0-9]*)\}", form))
    if used != set(contract["placeholders"]):
        fail(row_id + ": placeholder names differ from the source contract")


def validate_bundle(root, ready=False, complete=False):
    proof_bytes = bundle_path(root, "validation.json").read_bytes()
    if hashlib.sha256(proof_bytes).hexdigest() != EXPECTED_VALIDATION_SHA256:
        fail("validation.json changed; restore the exported validation files")
    proof = read_json(proof_bytes.decode("utf-8"))
    request_bytes = bundle_path(root, "request.json").read_bytes()
    if hashlib.sha256(request_bytes).hexdigest() != proof["requestSha256"]:
        fail("request.json changed; restore the exported request without editing its digest")
    request = read_json(request_bytes.decode("utf-8"))
    validate_schema(request, proof["requestSchema"], location="request")
    if request["sourceLocale"] != "en-US":
        fail("Expected en-US source locale")
    attestation = read_json(read_text(bundle_path(root, "attestation.json")))
    validate_schema(attestation, proof["attestationSchema"], location="attestation")
    if attestation["locale"] != request["locale"] or attestation["requestDigest"] != request["requestDigest"]:
        fail("Attestation answers a different locale or request")
    signatures = []
    for role in ("translator", "independentReviewer"):
        signature = attestation[role]
        name, date = signature["approvedBy"].strip(), signature["approvedAt"]
        if date and datetime.date.fromisoformat(date) > datetime.datetime.now(datetime.timezone.utc).date():
            fail(role + ": approval date has not happened yet")
        if ready and (not name or not date):
            fail(role + ": a named, dated human attestation is required")
        signatures.append(name)
    if all(signatures) and signatures[0].casefold() == signatures[1].casefold():
        fail("The translator and independent reviewer must be different people")
    rows, groups, answers = {}, {}, {}
    for row in request["rows"]:
        if row["id"] in rows:
            fail("Duplicate request row: " + row["id"])
        rows[row["id"]] = row
        bundle_path(root, row["file"])
        groups.setdefault(row["file"], []).append(row)
    for relative, group in groups.items():
        path = bundle_path(root, relative)
        if not path.is_file():
            fail("Missing requested payload: " + relative)
        if any(row["kind"] == "document" for row in group):
            if len(group) != 1 or not relative.startswith("documents/"):
                fail("A repository-qualified document must have exactly one row")
            text = read_text(path).replace("\r\n", "\n")
            if text.strip():
                answers[group[0]["id"]] = text
            continue
        seen = set()
        for entry in read_entries(path, request["format"], request["locale"]):
            if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
                fail(relative + ": entry has no string identity")
            row_id = entry["id"]
            if row_id not in rows or rows[row_id]["file"] != relative:
                fail("Unrequested answer row: " + row_id)
            if row_id in seen:
                fail("Duplicate answer row: " + row_id)
            seen.add(row_id)
            if entry.get("english") != rows[row_id]["english"]:
                fail("Answer changed the source text: " + row_id)
            text = entry.get("translation")
            if not isinstance(text, str):
                fail("Answer must be a string: " + row_id)
            if text.strip():
                if rows[row_id]["kind"] == "ruling" and text != "preserve-exact-english":
                    fail("Retired-name ruling must retain preserve-exact-english: " + row_id)
                if rows[row_id]["kind"] == "message":
                    validate_message(text, proof["messages"][row_id], row_id)
                answers[row_id] = text
        if seen != {row["id"] for row in group}:
            fail(relative + ": requested rows were removed; leave unanswered translations blank")
    missing = sorted(set(rows) - set(answers))
    if ready and not answers:
        fail("The returned bundle has no answers")
    if complete and missing:
        fail("Incomplete bundle: " + ", ".join(missing))
    return len(rows), len(answers), len(missing)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--ready", action="store_true", help="also require named and dated independent attestations")
    parser.add_argument("--complete", action="store_true", help="require every row answered and ready checks")
    args = parser.parse_args()
    try:
        total, answered, missing = validate_bundle(args.bundle.resolve(), args.ready or args.complete, args.complete)
    except (OSError, ValueError, KeyError, TypeError, csv.Error, ET.ParseError) as error:
        print("Bundle validation failed: " + str(error), file=sys.stderr)
        return 2
    print("Bundle structure valid: {} rows, {} answered, {} unanswered.".format(total, answered, missing))
    print("Local feedback only; this does not certify translation quality, human identity, source currency, or import acceptance.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
