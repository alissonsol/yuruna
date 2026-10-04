#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Maintain source, host, and guest SBOMs from repository files, without network access."""
# --- REGION: Imports
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ET
from urllib.parse import quote

sys.dont_write_bytecode = True
from sbom_dependencies import collect_dependencies, component_key
from sbom_provisioning import collect_provisioning

# --- REGION: Constants
# See https://yuruna.link/427fb0be-0001
SCOPES = ("repository", "hosts", "guests")
POLICY = "tools/sbom-policy.json"
TOOL_FILES = ("tools/Sync-Sbom.py", "tools/sbom_dependencies.py", "tools/sbom_provisioning.py")
OUTPUT = "docs/sbom/"
SWID_NS = "http://standards.iso.org/iso/19770/-2/2015/schema.xsd"
EXT_NS = "urn:yuruna:sbom:1"
ET.register_namespace("", SWID_NS)
ET.register_namespace("sbom", EXT_NS)
MANAGED = re.compile(r"^docs/sbom/(?:(?:repository|hosts|guests)\.(?:spdx\.json|cdx\.json|swidtag)|inventory\.json|swid/(?:repository|hosts|guests)-[a-f0-9]{20}\.swidtag)(?:\.previous)?$")

# --- REGION: Repository snapshot
def git(root, *args, input_data=None):
    """Run Git without invoking a shell or interpreting a repository path as an option."""
    result = subprocess.run(["git", "-C", str(root), *args], input=input_data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", "replace").strip() or "Git failed")
    return result.stdout


def read_snapshot(root, staged=False):
    """Read a working tree or all stage-zero index blobs, preserving binary bytes."""
    if not staged:
        paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
        files = {}
        for raw in sorted(set(paths.split(b"\0")) - {b""}):
            path = raw.decode("utf-8")
            target = root / path
            if target.is_symlink():
                files[path] = os.readlink(target).encode("utf-8")
            elif target.is_file():
                files[path] = target.read_bytes()
        return files
    entries = []
    for raw in git(root, "ls-files", "--stage", "-z").split(b"\0"):
        if not raw:
            continue
        info, raw_path = raw.split(b"\t", 1)
        mode, object_id, stage = info.split()
        if stage != b"0":
            raise RuntimeError("Resolve index conflicts before generating SBOMs")
        if mode == b"160000":
            raise RuntimeError("Git submodules require an explicit dependency declaration")
        entries.append((raw_path.decode("utf-8"), object_id.decode("ascii")))
    hashes = sorted({oid for _, oid in entries})
    if not hashes:
        return {}
    data = git(root, "cat-file", "--batch", input_data=("\n".join(hashes) + "\n").encode("ascii"))
    blobs, offset = {}, 0
    for expected in hashes:
        end = data.index(b"\n", offset)
        header = data[offset:end].decode("ascii").split()
        if len(header) != 3 or header[0] != expected or header[1] != "blob":
            raise RuntimeError("Could not read the staged source blob")
        size = int(header[2])
        offset = end + 1
        blobs[expected] = data[offset:offset + size]
        offset += size + 1
    return {path: blobs[oid] for path, oid in entries}


def source_files(files):
    """Exclude outputs and normalize text line endings for portable source identity."""
    return {name: canonical_bytes(data) for name, data in files.items() if not name.startswith(OUTPUT)}


def canonical_bytes(data):
    """Keep binary bytes exact; normalize CRLF only in UTF-8 source text."""
    if b"\0" not in data:
        try:
            data.decode("utf-8")
            return data.replace(b"\r\n", b"\n")
        except UnicodeDecodeError:
            pass
    return data


def input_digest(files):
    """Hash framed paths and bytes, avoiding ambiguous concatenation and wall-clock churn."""
    digest = hashlib.sha256()
    for name, data in sorted(files.items()):
        path = name.encode("utf-8")
        digest.update(len(path).to_bytes(8, "big") + path)
        digest.update(len(data).to_bytes(8, "big") + data)
    return digest.hexdigest()


def load_policy(files):
    """Validate the repository's recorded creator and source metadata."""
    if POLICY not in files:
        raise RuntimeError(f"Missing {POLICY}; stage the policy before running the hook")
    policy = json.loads(files[POLICY])
    required = ("name", "source", "creator", "creatorRegid", "created", "licenseId", "licensePath")
    if policy.get("schema") != "yuruna.sbom-policy/v1" or any(not policy.get(k) for k in required):
        raise RuntimeError("Invalid SBOM policy")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", policy["created"]):
        raise RuntimeError("The SBOM creation date must be recorded in UTC")
    if policy["licensePath"] not in files:
        raise RuntimeError("The declared repository license file is missing")
    return policy

# --- REGION: Component identity
def record_id(record):
    """Use a stable ID for a component's ecosystem, name, and established version."""
    return hashlib.sha256(component_key(record).encode("utf-8")).hexdigest()[:20]


def normalized(records):
    """Merge source witnesses without silently guessing a version or supplier."""
    result = {}
    for item in records:
        record = dict(item)
        if not isinstance(record.get("name"), str) or not record["name"].strip():
            raise RuntimeError("A collector returned a component without a name")
        key = component_key(record)
        if key not in result:
            result[key] = record
        else:
            previous = result[key]
            for field, plural in (("group", "groups"), ("scope", "scopes"), ("versionConstraint", "versionConstraints")):
                values = set(previous.get(plural, [])) | set(record.get(plural, []))
                values.update(item[field] for item in (previous, record) if item.get(field))
                if len(values) > 1:
                    previous.pop(field, None)
                    previous[plural] = sorted(values)
                elif values:
                    previous[field] = next(iter(values))
            for field in ("evidence", "hashes", "notes", "dependencies"):
                previous[field] = list(previous.get(field, [])) + list(record.get(field, []))
            if record.get("completeness") == "unresolved":
                previous["completeness"] = "unresolved"
    for record in result.values():
        for field in ("evidence", "hashes", "notes", "dependencies"):
            if field in record:
                values = {json.dumps(v, sort_keys=True): v for v in record[field]}
                record[field] = [values[k] for k in sorted(values)]
    records = [result[k] for k in sorted(result)]
    if len({record_id(r) for r in records}) != len(records):
        raise RuntimeError("Component identifiers collided")
    return records


def purl(record):
    """Emit package URLs only where the source establishes the package identity."""
    if record.get("purl"):
        return record["purl"]
    name, version = record["name"], record.get("version")
    if any(c in name for c in "$ {}()") or (version and re.search(r"[\s^~*<>=|$]", version)):
        return None
    kinds = {"npm": "npm", "cargo": "cargo", "nuget": "nuget", "golang": "golang", "go": "golang", "pypi": "pypi", "pip": "pypi"}
    kind = kinds.get(record.get("ecosystem"))
    if not kind:
        return None
    value = f"pkg:{kind}/{quote(name, safe='/')}"
    return value + ("@" + quote(version, safe="") if version else "")


def record_note(record):
    """Preserve declaration and source evidence in formats without matching native fields."""
    return json.dumps({k: record[k] for k in ("ecosystem", "group", "groups", "scope", "scopes", "completeness", "versionConstraint", "versionConstraints", "evidence", "notes") if k in record}, ensure_ascii=False, sort_keys=True)


def json_bytes(value):
    """Write deterministic UTF-8, LF, and a final newline."""
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")

# --- REGION: SPDX
def spdx_document(policy, scope, records, files, digest):
    """Render ISO/IEC 5962:2021 (SPDX 2.2.1; the wire version is SPDX-2.2)."""
    root_id = "SPDXRef-Repository"
    version = files.get("VERSION", b"").decode("utf-8").strip()
    root_package = {"name": f"{policy['name']}-{scope}", "SPDXID": root_id,
                    "downloadLocation": policy["source"], "filesAnalyzed": False,
                    "licenseConcluded": "NOASSERTION", "licenseDeclared": policy["licenseId"],
                    "copyrightText": "NOASSERTION", "supplier": "Organization: " + policy["creator"],
                    "comment": f"Declared {scope} inventory; source-inputs SHA256 {digest}. Not an installed-system scan."}
    if version:
        root_package["versionInfo"] = version
    packages, relations = [root_package], [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": root_id}]
    ids = {component_key(r): "SPDXRef-" + record_id(r) for r in records}
    for record in records:
        identifier = ids[component_key(record)]
        package = {"name": record["name"], "SPDXID": identifier,
                   "downloadLocation": record.get("downloadLocation", "NOASSERTION"), "filesAnalyzed": False,
                   "licenseConcluded": "NOASSERTION", "licenseDeclared": record.get("license", "NOASSERTION"),
                   "copyrightText": "NOASSERTION", "comment": record_note(record)}
        if record.get("version"):
            package["versionInfo"] = record["version"]
        hashes = [{"algorithm": h["alg"].replace("-", ""), "checksumValue": h["content"].lower()} for h in record.get("hashes", []) if h["alg"].replace("-", "") in {"SHA1", "SHA256", "SHA384", "SHA512", "MD5"}]
        if hashes:
            package["checksums"] = hashes
        url = purl(record)
        if url:
            package["externalRefs"] = [{"referenceCategory": "PACKAGE_MANAGER", "referenceType": "purl", "referenceLocator": url}]
        packages.append(package)
        relations.append({"spdxElementId": root_id, "relationshipType": "DEPENDS_ON", "relatedSpdxElement": identifier})
        for dependency in record.get("dependencies", []):
            if dependency in ids:
                relations.append({"spdxElementId": identifier, "relationshipType": "DEPENDS_ON", "relatedSpdxElement": ids[dependency]})
    document = {"spdxVersion": "SPDX-2.2", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
                "name": f"{policy['name']}-{scope}", "documentNamespace": f"{policy['source']}/sbom/{scope}/{digest}",
                "creationInfo": {"created": policy["created"], "creators": ["Tool: Sync-Sbom.py-1", "Organization: " + policy["creator"]],
                                 "comment": "Created date is the initial inventory creation date. Source digest identifies each regenerated inventory. Unrecorded licenses and transitive dependencies remain unasserted."},
                "documentDescribes": [root_id], "packages": packages, "relationships": relations}
    if policy["licenseId"].startswith("LicenseRef-"):
        document["hasExtractedLicensingInfos"] = [{"licenseId": policy["licenseId"], "name": policy["licenseId"],
                                                   "extractedText": files[policy["licensePath"]].decode("utf-8"),
                                                   "seeAlsos": [policy["source"] + "/blob/main/" + policy["licensePath"]]}]
    return document

# --- REGION: CycloneDX
def cdx_document(policy, scope, records, files, digest):
    """Render ECMA-424 second edition (CycloneDX JSON 1.7)."""
    root_ref = "repository-" + scope
    root_component = {"type": "application", "bom-ref": root_ref, "name": f"{policy['name']}-{scope}",
                      "properties": [{"name": "yuruna:source-inputs-sha256", "value": digest},
                                     {"name": "yuruna:inventory-kind", "value": "declared-source"}]}
    version = files.get("VERSION", b"").decode("utf-8").strip()
    if version:
        root_component["version"] = version
    ids = {component_key(r): "component-" + record_id(r) for r in records}
    components = []
    dependencies = [{"ref": root_ref, "dependsOn": sorted(ids.values())}]
    for record in records:
        identifier = ids[component_key(record)]
        kind = record.get("kind", "library")
        component = {"type": kind if kind in {"application", "library", "framework", "container", "platform", "operating-system", "file"} else "library",
                     "bom-ref": identifier, "name": record["name"],
                     "properties": [{"name": "yuruna:declaration", "value": record_note(record)}]}
        if record.get("version"):
            component["version"] = record["version"]
        if record.get("group"):
            component["group"] = record["group"]
        if record.get("scope") == "optional":
            component["scope"] = "optional"
        url = purl(record)
        if url:
            component["purl"] = url
        hashes = [{"alg": h["alg"] if "-" in h["alg"] else h["alg"].replace("SHA", "SHA-"), "content": h["content"].lower()} for h in record.get("hashes", []) if h["alg"].replace("-", "") in {"SHA1", "SHA256", "SHA384", "SHA512", "MD5"}]
        if hashes:
            component["hashes"] = hashes
        license_id = record.get("license")
        if license_id and license_id not in {"NOASSERTION", "NONE"}:
            component["licenses"] = [{"expression": license_id}]
        components.append(component)
        edges = sorted({ids[d] for d in record.get("dependencies", []) if d in ids})
        # An empty edge list would assert no dependencies; omit unknown graphs.
        if edges or record.get("completeness") == "locked":
            dependencies.append({"ref": identifier, "dependsOn": edges})
    return {"bomFormat": "CycloneDX", "specVersion": "1.7", "serialNumber": "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, policy["source"] + "/" + scope + "/" + digest)),
            "version": 1, "metadata": {"component": root_component}, "components": components,
            "dependencies": dependencies,
            "compositions": [{"aggregate": "incomplete", "assemblies": [root_ref]}]}

# --- REGION: SWID
def swid_tag(policy, scope, name, version, tag_id, record=None, links=()):
    """Identify source software with corpus tags, without asserting installation."""
    root = ET.Element(f"{{{SWID_NS}}}SoftwareIdentity", {"name": name, "tagId": "urn:uuid:" + tag_id,
                     "version": version or "unspecified", "versionScheme": "alphanumeric", "tagVersion": "0", "corpus": "true"})
    ET.SubElement(root, f"{{{SWID_NS}}}Entity", {"name": policy["creator"], "regid": policy["creatorRegid"], "role": "tagCreator"})
    meta = {f"{{{EXT_NS}}}generator": "tools/Sync-Sbom.py", f"{{{EXT_NS}}}scope": scope,
            f"{{{EXT_NS}}}inventory-kind": "declared-source"}
    if record:
        meta[f"{{{EXT_NS}}}declaration"] = record_note(record)
        if record.get("hashes"):
            meta[f"{{{EXT_NS}}}hashes"] = json.dumps(record["hashes"], sort_keys=True)
    ET.SubElement(root, f"{{{SWID_NS}}}Meta", meta)
    for href in links:
        ET.SubElement(root, f"{{{SWID_NS}}}Link", {"rel": "requires", "href": href})
    ET.indent(root, space="  ")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"

# --- REGION: Inventory generation
def generate(files):
    """Generate every scope from one immutable snapshot, with traceable source hashes."""
    policy = load_policy(files)
    inputs = source_files(files)
    digest = input_digest(inputs)
    provisioning = collect_provisioning(inputs, policy["name"])
    python_line = next(i for i, line in enumerate(inputs["tools/sbom_dependencies.py"].decode("utf-8").splitlines(), 1) if line.strip() == "import tomllib")
    git_line = next(i for i, line in enumerate(inputs["tools/Sync-Sbom.py"].decode("utf-8").splitlines(), 1) if 'subprocess.run(["git"' in line)
    tool_dependencies = [{"name": "Python", "ecosystem": "python", "versionConstraint": ">=3.11", "kind": "platform", "scope": "build",
                          "completeness": "declared", "evidence": [{"path": "tools/sbom_dependencies.py", "line": python_line, "detail": "SBOM collector uses Python 3.11 tomllib and the standard library"}],
                          "notes": ["No Python package installation is required."]},
                         {"name": "Git", "ecosystem": "git", "kind": "application", "scope": "build", "completeness": "unresolved",
                          "evidence": [{"path": "tools/Sync-Sbom.py", "line": git_line, "detail": "Index snapshot and generated-file staging use the installed Git CLI"}],
                          "notes": ["The repository does not pin the installed Git version."]}]
    scopes = {"repository": normalized(collect_dependencies(inputs, policy["name"]) + tool_dependencies),
              "hosts": normalized(provisioning.get("hosts", [])), "guests": normalized(provisioning.get("guests", []))}
    output = {}
    for scope, records in scopes.items():
        output[f"{OUTPUT}{scope}.spdx.json"] = json_bytes(spdx_document(policy, scope, records, inputs, digest))
        output[f"{OUTPUT}{scope}.cdx.json"] = json_bytes(cdx_document(policy, scope, records, inputs, digest))
        links = []
        for record in records:
            name = f"swid/{scope}-{record_id(record)}.swidtag"
            links.append(name)
            tag_id = str(uuid.uuid5(uuid.NAMESPACE_URL, policy["source"] + "/" + scope + "/" + component_key(record)))
            output[OUTPUT + name] = swid_tag(policy, scope, record["name"], record.get("version"), tag_id, record)
        root_tag_id = str(uuid.uuid5(uuid.NAMESPACE_URL, policy["source"] + "/" + scope + "/" + digest))
        output[f"{OUTPUT}{scope}.swidtag"] = swid_tag(policy, scope, f"{policy['name']}-{scope}", inputs.get("VERSION", b"").decode().strip(), root_tag_id, links=links)
    output[OUTPUT + "inventory.json"] = json_bytes({"schema": "yuruna.sbom-inventory/v1", "generator": "tools/Sync-Sbom.py",
                 "name": policy["name"], "sourceInputsSha256": digest,
                 "sourceFiles": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(inputs.items())},
                 "counts": {scope: len(records) for scope, records in scopes.items()}, "components": scopes,
                 "coverage": provisioning.get("coverage", []),
                 "limitations": ["Inventories describe repository declarations, not installed machines.",
                                 "No package restores, external resolution, vulnerability scan, or inferred licenses.",
                                 "Floating versions and transitives absent from existing manifests/locks remain unresolved."]})
    validate_outputs(output)
    return output


def validate_outputs(output):
    """Enforce the generator's required fields, unique references, and local SWID links."""
    for path, data in output.items():
        if path.endswith(".spdx.json"):
            doc = json.loads(data)
            ids = {p["SPDXID"] for p in doc["packages"]} | {doc["SPDXID"]}
            if len(ids) != len(doc["packages"]) + 1:
                raise RuntimeError("Duplicate SPDX identifiers")
            for relation in doc["relationships"]:
                if relation["spdxElementId"] not in ids or relation["relatedSpdxElement"] not in ids:
                    raise RuntimeError("Unresolved SPDX relationship")
        elif path.endswith(".cdx.json"):
            doc = json.loads(data)
            refs = {doc["metadata"]["component"]["bom-ref"]} | {c["bom-ref"] for c in doc["components"]}
            if len(refs) != len(doc["components"]) + 1:
                raise RuntimeError("Duplicate CycloneDX references")
            for relation in doc["dependencies"]:
                if relation["ref"] not in refs or any(ref not in refs for ref in relation["dependsOn"]):
                    raise RuntimeError("Unresolved CycloneDX relationship")
        elif path.endswith(".swidtag"):
            root = ET.fromstring(data)
            if not root.get("tagId") or not root.get("name") or not root.get("version"):
                raise RuntimeError("Missing SWID identity")
            for link in root.findall(f"{{{SWID_NS}}}Link"):
                target = str(Path(path).parent / link.get("href", "")).replace("\\", "/")
                if target not in output:
                    raise RuntimeError("Unresolved SWID component link")

# --- REGION: Safe output maintenance
def plan_changes(files, output):
    """Save the prior bytes once per actual change, including retired component tags."""
    current = {path: data for path, data in files.items() if MANAGED.fullmatch(path) and not path.endswith(".previous")}
    writes, removals = {}, []
    for path, data in output.items():
        old = current.get(path)
        if old != data:
            if old is not None:
                writes[path + ".previous"] = old
            writes[path] = data
    for path, old in current.items():
        if path not in output:
            writes[path + ".previous"] = old
            removals.append(path)
    return writes, removals


def apply_changes(root, files, writes, removals, staged=False, stage=False):
    """Protect unstaged output edits and roll back files if staging fails."""
    targets = sorted(set(writes) | set(removals))
    saved = {}
    for path in targets:
        if not MANAGED.fullmatch(path):
            raise RuntimeError("Refusing to write outside managed SBOM paths")
        target = root / path
        if target.is_symlink() or any(p.is_symlink() for p in target.parents if p != root.parent):
            raise RuntimeError("Refusing a symlink in an SBOM output path")
        old = target.read_bytes() if target.is_file() else None
        saved[path] = old
        if staged and old != files.get(path):
            raise RuntimeError(f"Unstaged SBOM edits in {path}; stage or preserve them before committing")
    temps = []
    try:
        for path, data in writes.items():
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            descriptor, temp_name = tempfile.mkstemp(prefix=".sbom-", suffix=".tmp", dir=target.parent)
            temp = Path(temp_name)
            temps.append(temp)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
            os.replace(temp, target)
        for path in removals:
            (root / path).unlink(missing_ok=True)
        if stage and targets:
            if source_files(read_snapshot(root, staged=True)) != source_files(files):
                raise RuntimeError("The staged source changed while generating SBOMs; retry the commit")
            # One Git transaction stages only generated paths, including deletions.
            git(root, "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul",
                input_data=b"\0".join(path.encode("utf-8") for path in targets) + b"\0")
    except BaseException:
        for path, old in saved.items():
            target = root / path
            if old is None:
                target.unlink(missing_ok=True)
            else:
                target.write_bytes(old)
        raise
    finally:
        for temp in temps:
            temp.unlink(missing_ok=True)

# --- REGION: Entry point
def main(argv=None):
    """Update working-tree artifacts or stage an exact index-derived inventory."""
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--update", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--staged", action="store_true")
    parser.add_argument("--stage", action="store_true")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args(argv)
    if args.stage and (not args.staged or args.check):
        parser.error("--stage requires --staged and cannot be combined with --check")
    try:
        root = args.root.resolve()
        files = read_snapshot(root, args.staged)
        if args.staged:
            for path in TOOL_FILES:
                target = root / path
                if path not in files or not target.is_file() or canonical_bytes(target.read_bytes()) != canonical_bytes(files[path]):
                    raise RuntimeError(f"Generator differs from the index: {path}; stage the generator before committing")
        output = generate(files)
        writes, removals = plan_changes(files, output)
        if args.check:
            if writes or removals:
                print("SBOMs are stale: " + ", ".join(sorted(set(writes) | set(removals))))
                return 1
        else:
            apply_changes(root, files, writes, removals, args.staged, args.stage)
        counts = json.loads(output[OUTPUT + "inventory.json"])["counts"]
        print(f"SBOM {load_policy(files)['name']}: " + ", ".join(f"{s} {counts[s]}" for s in SCOPES) + f"; {len(writes)} written, {len(removals)} retired" + ("; staged" if args.stage else ""))
        return 0
    except (OSError, ValueError, RuntimeError, UnicodeError, ET.ParseError) as error:
        print(f"SBOM: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
