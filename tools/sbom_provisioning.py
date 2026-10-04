# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Collect declared host and guest provisioning inputs without executing them.

This is an inventory of source declarations, including conditional alternatives.
It never claims that a command ran or resolves a package repository. Dynamic
inputs, externally supplied defaults and unsupported installers remain coverage
notes instead of fabricated package names or versions.
"""

from __future__ import annotations

import re
import shlex
from pathlib import PurePosixPath
from urllib.parse import urlsplit


# --- REGION: Source selection and lexical preparation
_MANAGERS = re.compile(
    r"(?<![\w.-])(?P<manager>apt-get|apt|dnf|yum|brew|winget|npm|pip3?|cargo|"
    r"rustup|nvm|dotnet)\s+(?P<prefix>(?:(?:-[\w-]+)\s+)*)"
    r"(?P<action>install|add|groupinstall|toolchain\s+install|tool\s+install)\b",
    re.I,
)
_PS_INSTALL = re.compile(r"(?<![\w.-])(Install-Module|Install-PSResource|Install-PackageProvider|Install-WingetPackage)\b", re.I)
_CONTAINER = re.compile(r"(?<![\w.-])(?:docker|podman)\s+(pull|run|create)\b", re.I)
_DOWNLOAD = re.compile(r"(?<![\w.-])(?:curl(?:_retry)?|wget(?:_try)?|Invoke-WebRequest|Start-BitsTransfer|Save-CachedHttpUri|Save-YurunaImage|Save-ImageWithChecksum)\b", re.I)
_URL = re.compile(r"https?://[^\s\"'<>`]+")
_VARIABLE = re.compile(r"\$\{([^}]+)\}|\$\(([A-Za-z_][\w]*)\)|\$([A-Za-z_][\w]*)")
_DIAGNOSTIC = re.compile(r"^(?:echo|printf|log|warn|die|err|note_issue|Write-[A-Za-z]+|Add-InstallIssue)\b", re.I)
_IGNORED_PARTS = {"docs", "dev-only", "globalization", ".git", "node_modules", "vendor", "fixtures", "fixture", "tests", "__pycache__"}
_VALUE_OPTIONS = {"-o", "-c", "--config-file", "--target-release", "-t", "--index-url", "--extra-index-url", "--trusted-host", "--prefix", "--target", "--python", "--cache-dir", "--registry", "--workspace", "--userconfig", "--root", "--releasever", "--enablerepo", "--disablerepo", "--installroot", "--setopt", "--source", "--scope", "--location", "--architecture", "--version", "--tag", "--git", "--branch", "--features", "--profile", "--default-toolchain", "--toolchain", "--package", "--arch"}


def _eligible(path: str) -> bool:
    parts = PurePosixPath(path).parts
    lower = path.lower()
    if any(part.lower() in _IGNORED_PARTS for part in parts):
        return False
    if any(token in lower for token in (".tests.", ".test.", "_test.", "test_", "fixture")):
        return False
    # Maintenance tools and test runners do not provision installed software;
    # two tools do. example-workload.sh is shipped into example guests and
    # starts their registry, and Install-TestModule.ps1 is run by every host
    # installer to install Pester and PSScriptAnalyzer.
    if lower.startswith("tools/") and lower not in {"tools/example-workload.sh", "tools/install-testmodule.ps1"}:
        return False
    if lower.startswith("test/") and not (
        lower.startswith("test/service/") or lower.startswith("test/lab/")
        or PurePosixPath(lower).name in {"initialize-lab.ps1", "amisad.lab.psm1", "amisad.hostcommon.ps1"}
    ):
        return False
    return (lower.endswith((".sh", ".ps1", ".psm1", ".yml", ".yaml", ".tf", ".user-data"))
            or PurePosixPath(lower).name == "dockerfile")


def _without_comments(text: str) -> str:
    """Remove PowerShell block help and hash comments, retaining source lines."""
    text = re.sub(r"(?s)<#.*?#>", lambda m: "\n" * m.group().count("\n"), text)
    lines = []
    for line in text.splitlines():
        quote = None
        escaped = False
        end = len(line)
        for index, character in enumerate(line):
            if escaped:
                escaped = False
                continue
            if character in "\\`" and quote != "'":
                escaped = True
                continue
            if quote:
                if character == quote:
                    quote = None
            elif character in "\"'":
                quote = character
            elif character == "#" and (index == 0 or line[index - 1].isspace()):
                end = index
                break
        lines.append(line[:end])
    return "\n".join(lines)


def _mask_help_strings(text: str) -> str:
    """Keep executable/generated here strings; blank multiline operator advice."""
    pattern = re.compile(r"(?ms)^(?P<prefix>[^\n]*?)@(?P<quote>['\"])\r?\n(?P<body>.*?)\n[ \t]*(?P=quote)@")
    def replace(match):
        prefix, body = match["prefix"], match["body"]
        variable = re.search(r"\$([A-Za-z_][\w]*)\s*=\s*$", prefix)
        executed = bool(variable and re.search(r"(?:-Command\s+|Invoke-Expression\s+|Set-Content[^\n]*-Value\s+)\$" + re.escape(variable[1]) + r"\b", text, re.I))
        generated = bool(re.search(r"(?m)^\s*(?:#cloud-config|#!|autoinstall:|write_files:|runcmd:)", body))
        if (executed or generated) and not _DIAGNOSTIC.match(prefix.strip()):
            return match.group()
        return "\n" * match.group().count("\n")
    return pattern.sub(replace, text)


def _active_matches(pattern: re.Pattern, command: str):
    """Reject command words inside data strings unless a shell executes them."""
    quoted = set()
    quote = None
    escaped = False
    for index, character in enumerate(command):
        if quote:
            quoted.add(index)
        if escaped:
            escaped = False
            continue
        if character in "\\`" and quote != "'":
            escaped = True
            continue
        if quote:
            if character == quote:
                quote = None
        elif character in "'\"":
            quote = character
    for match in pattern.finditer(command):
        prefix = command[:match.start()]
        executed = bool(re.search(r"\b(?:pwsh|powershell|sh|bash)\b[^;]*\s(?:-Command|-c)\s", prefix, re.I))
        # A one-line PowerShell command body used by the guest update scripts.
        assigned_script = bool(re.match(r"\$yamlInstall\s*=", command, re.I))
        if match.start() not in quoted or executed or assigned_script:
            yield match


def _logical_lines(text: str):
    """Join shell/PowerShell continuations and mask printed heredoc prose."""
    pending = ""
    first = 0
    heredoc = None
    discard = False
    for number, raw in enumerate(text.splitlines(), 1):
        stripped = raw.strip()
        if heredoc:
            if stripped == heredoc:
                heredoc = None
                discard = False
                continue
            if discard:
                continue
        marker = re.search(r"<<-?\s*['\"]?([A-Za-z_][\w]*)['\"]?", raw)
        if marker:
            heredoc = marker[1]
            # File/script construction and PowerShell input are executable
            # declarations; bare cat heredocs just print installation advice.
            discard = not (re.search(r"(?:>|\btee\b|\bpwsh\b|\bpowershell\b|\bbash\b|\bsh\b)", raw))
        if not pending:
            first = number
        pending += (" " if pending else "") + stripped
        if stripped.endswith(("\\", "`")):
            pending = pending[:-1]
            continue
        yield first, pending
        pending = ""
    if pending:
        yield first, pending


def _tokens(value: str) -> list[str]:
    try:
        return shlex.split(value, posix=True)
    except ValueError:
        return re.findall(r"[^\s]+", value)


# --- REGION: Literal values and source-only uncertainty
def _bindings(text: str) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    # Arrays are read as declarations, not executed. A later append contributes
    # conditional architecture alternatives, each retained as separate values.
    arrays = re.compile(r"(?m)(?:\$)?([A-Za-z_][\w]*)\s*(\+?=)\s*@?\(([^)]*)\)")
    for match in arrays.finditer(text):
        if "$([" in match[3] or "$([" in match[0]:
            continue
        values = [token.strip(",\"'") for token in _tokens(match[3])]
        values = [v for v in values if v and re.fullmatch(r"[\w$@{}[\]*.+:/=-]+", v) and not v.startswith(("#", "@{"))]
        if values:
            result.setdefault(match[1].lower(), []).extend(values)
    assignment = re.compile(r"(?m)(?:^\s*|[;{)]\s*|\bexport\s+|\blocal\s+|\bARG\s+)(?:\$)?([A-Za-z_][\w]*)\s*=\s*(?:\"([^\"\n]*)\"|'([^'\n]*)'|([^\s;\n]+))")
    for match in assignment.finditer(text):
        value = next((part for part in match.groups()[1:] if part is not None), "")
        if not value or value.startswith(("$(", "@(", "(", "[")) or re.search(r"[;|&]", value):
            continue
        key = match[1].lower()
        if value not in result.setdefault(key, []):
            result[key].append(value)
    return result


def _expand(value: str, values: dict[str, list[str]], depth: int = 0) -> list[str]:
    if depth > 5:
        return [value]
    value = re.sub(r"\$\{[^{}]*:\+[^{}]*(?:\$\{[^{}]*\}[^{}]*)*\}", "", value)
    match = _VARIABLE.search(value)
    if not match:
        return [value]
    expression = next(part for part in match.groups() if part is not None)
    if ":+" in expression:
        # A cache query suffix does not identify a different software artifact.
        choices = [""]
    else:
        name, _, default = expression.partition(":-")
        name = name.rstrip("[@*]")
        choices = values.get(name.lower(), [default] if default else [])
        if default:
            choices = [default if choice == match.group() else choice for choice in choices]
    if not choices:
        return [value]
    output = []
    for choice in choices[:32]:
        if choice == match.group():
            continue
        replaced = value[:match.start()] + choice + value[match.end():]
        output.extend(_expand(replaced, values, depth + 1))
        if len(output) >= 64:
            break
    return sorted(set(output))[:64] or [value]


def _literal(value: str) -> bool:
    return bool(value and not re.search(r"[$`{}]|PLACEHOLDER|\b(?:true|false|null)\b", value, re.I)
                and not (value.startswith("@") and "/" not in value))


def _target(path: str, command: str = "") -> tuple[str, str]:
    lower = path.lower()
    if "curtin in-target" in command or "vmconfig/" in lower or lower.startswith("guest/"):
        bucket = "guests"
    elif PurePosixPath(lower).name == "dockerfile" or any(part in lower for part in ("/workloads/", "/components/", "/resources/")):
        bucket = "guests"
    elif re.search(r"/(?:guest\.[^/]+|seed[^/]*)/", lower):
        bucket = "guests"
    elif re.search(r"/(?:guest|test)/(?:ubuntu\.server|amazon\.linux|windows\.|macos\.)", lower):
        bucket = "guests"
    elif "service-bringup" in lower or "guestseed" in lower:
        bucket = "guests"
    else:
        bucket = "hosts"
    patterns = (
        (r"(?:windows\.hyper-v|windows\.11)", "windows"),
        (r"(?:macos\.utm|macos\.26)", "macos"),
        (r"amazon\.linux\.2023", "amazon-linux-2023"),
        (r"ubuntu\.server\.(24|26)", None),
        (r"ubuntu\.kvm", "ubuntu-kvm"),
        (r"ubuntu\.server|ubuntu\.", "ubuntu-shared"),
    )
    os_path = lower.split("/guest.", 1)[-1] if bucket == "guests" else lower
    if bucket == "guests" and "new-ubuntuservervm" in lower:
        os_path = "ubuntu.server"
    for pattern, label in patterns:
        match = re.search(pattern, os_path)
        if match:
            return bucket, label or "ubuntu-server-" + match[1]
    if "vmconfig/" in lower:
        return bucket, "ubuntu-service-seed"
    if PurePosixPath(lower).name == "dockerfile":
        return bucket, "container"
    return bucket, "shared-or-configured"


def _package(value: str, ecosystem: str) -> tuple[str, str | None]:
    if ecosystem in {"apt", "apk"} and "=" in value:
        return tuple(value.split("=", 1))
    if ecosystem == "pypi":
        match = re.fullmatch(r"([^<>=!~\[]+)(?:\[[^]]+\])?==([^*]+)", value)
        if match:
            return match[1], match[2]
        return re.split(r"[<>=!~\[]", value, 1)[0], None
    if ecosystem == "npm":
        split = value.rfind("@")
        if split > 0:
            name, requested = value[:split], value[split + 1:]
            return name, requested if re.fullmatch(r"v?\d+\.\d+\.\d+(?:[-+][\w.-]+)?", requested) else None
    if ecosystem == "homebrew" and "@" in value:
        # A Homebrew versioned formula is a release line, not an exact build.
        return value, None
    return value, None


# --- REGION: Collector
class _Collector:
    def __init__(self, repo_name: str):
        self.repo_name = repo_name
        self.records: dict[tuple, dict] = {}
        self.coverage: list[dict] = []

    def note(self, path: str, line: int, detail: str, status: str = "unresolved"):
        note = {"path": path, "line": line, "detail": detail, "status": status}
        if note not in self.coverage:
            self.coverage.append(note)

    def add(self, path: str, line: int, name: str, ecosystem: str, detail: str,
            version: str | None = None, kind: str = "application", scope: str = "runtime",
            bucket: str | None = None, hashes: list | None = None, constraint: str | None = None):
        inferred, os_name = _target(path, detail)
        bucket = bucket or inferred
        group = f"{self.repo_name}:{bucket}:{os_name}"
        evidence = {"path": path, "line": line, "detail": f"target={os_name}; {detail}"}
        key = (bucket, group, ecosystem, name, version or "", scope)
        if key not in self.records:
            record = {"name": name, "kind": kind, "ecosystem": ecosystem, "group": group,
                      "scope": scope, "evidence": [], "hashes": [], "dependencies": [],
                      "completeness": "source-declared",
                      "notes": ["Conditional source declaration; installed state and transitive dependencies are not resolved."]}
            if version:
                record["version"] = version
            elif constraint:
                record["versionConstraint"] = constraint
            self.records[key] = record
        record = self.records[key]
        if evidence not in record["evidence"]:
            record["evidence"].append(evidence)
        for item in hashes or []:
            if item not in record["hashes"]:
                record["hashes"].append(item)

    def packages(self, path: str, line: int, args: str, manager: str, action: str,
                 values: dict[str, list[str]], *, version: str | None = None):
        ecosystem = {"apt-get": "apt", "pip": "pypi", "pip3": "pypi", "brew": "homebrew",
                     "cargo": "cargo", "Install-Module": "psgallery", "Install-PSResource": "psgallery"}.get(manager, manager)
        tokens = _tokens(args)
        candidates = []
        index = 0
        while index < len(tokens):
            item = tokens[index].strip(",\"'")
            terminal = item.endswith(";")
            item = item.rstrip(";")
            if item in {";", "&&", "||", "|", "then", "fi", "}", ")", ";;"} or item.startswith((";", "|", ">", "2>", "1>")):
                break
            if item in {"--simulate", "-s", "--download-only"} and manager in {"apt", "apt-get"}:
                self.note(path, line, f"{manager} {action}: repository probe or cache-only download", "excluded")
                return
            if item.startswith("-"):
                if item in _VALUE_OPTIONS or item in {"-r", "--requirement", "-c", "--constraint"}:
                    if index + 1 < len(tokens):
                        if item in {"--version", "--tag"} and _literal(tokens[index + 1]):
                            version = tokens[index + 1]
                        if item in {"-r", "--requirement", "--constraint"}:
                            self.note(path, line, f"{manager} {action}: dependencies from {tokens[index + 1]}; consult the dependency manifest inventory")
                        index += 1
                index += 1
                continue
            if re.match(r"\d*[<>]|\d+>&", item):
                break
            for expanded in _expand(item, values):
                if not _literal(expanded):
                    self.note(path, line, f"{manager} {action}: unresolved package expression {item}")
                elif expanded not in {"Out-Null", "-", "true"} and not expanded.startswith(("http:", "https:", "/")):
                    candidates.append(expanded)
            index += 1
            if terminal:
                break
        for candidate in candidates:
            name, package_version = _package(candidate, ecosystem)
            if not re.fullmatch(r"[@\w][\w.@/+:-]*(?:[<>=!~].*)?", candidate):
                self.note(path, line, f"{manager} {action}: unparsed package token {candidate}")
                continue
            detail = f"action={manager} {action}; requested={candidate}; conditional provisioning input"
            if not (package_version or version):
                detail += "; installed version and transitive dependencies unresolved"
            declared_version = package_version or version
            constraint = None
            if declared_version and re.search(r"[$*<>=~^]|^(?:latest|stable|main|master)$", declared_version):
                constraint, declared_version = declared_version, None
            elif ecosystem == "npm" and candidate.rfind("@") > 0 and not declared_version:
                constraint = candidate[candidate.rfind("@") + 1:]
            elif ecosystem == "pypi" and not declared_version and re.search(r"[<>=!~]", candidate):
                constraint = candidate[len(name):]
            self.add(path, line, name, ecosystem, detail, declared_version, constraint=constraint)
        if not candidates:
            self.note(path, line, f"{manager} {action}: no literal package names; dynamic arguments or a project manifest")

    def scan(self, path: str, raw: str, common: dict[str, list[str]]):
        text = _without_comments(_mask_help_strings(raw))
        values = dict(common)
        values.update(_bindings(text))
        self._seed_packages(path, text)
        stages = set()
        for line, command in _logical_lines(text):
            if not command:
                continue
            if "vmconfig/" in path.lower() or "#cloud-config" in raw or re.search(r"(?m)^\s*runcmd:", raw):
                sequence_command = re.fullmatch(r"-\s*(['\"])(.*)\1", command)
                if sequence_command:
                    command = sequence_command[2].replace("''", "'")
            quoted_executable = re.match(r"^['\"](?:\$[^'\"\s]+|[/~][^'\"]+)['\"]\s+", command)
            if _DIAGNOSTIC.match(command) or (re.match(r"^[\"']", command) and not quoted_executable):
                continue
            # Function declarations are not invocations. Their bodies are still
            # scanned, and unresolved parameterized installs get coverage notes.
            if re.match(r"^(?:function\s+)?[\w-]+\s*\(\s*\)\s*\{", command, re.I):
                continue
            if PurePosixPath(path).name.lower() == "dockerfile":
                image = re.match(r"FROM\s+(?:--platform=\S+\s+)?(\S+)(?:\s+AS\s+(\S+))?", command, re.I)
                if image:
                    if image[1].lower() not in stages:
                        for expanded in _expand(image[1], values):
                            self.image(path, line, expanded, "Dockerfile FROM", "build" if image[2] and image[2].lower() == "build" else "runtime")
                    if image[2]:
                        stages.add(image[2].lower())
            for match in _active_matches(_MANAGERS, command):
                manager, action = match["manager"].lower(), match["action"].lower()
                if manager == "winget":
                    continue
                if manager == "dotnet" and action != "tool install":
                    continue
                if manager in {"nvm", "rustup"}:
                    requested = _tokens(command[match.end():])
                    for item in requested[:1]:
                        for expanded in _expand(item, values):
                            exact = expanded if re.fullmatch(r"v?\d+\.\d+\.\d+", expanded) else None
                            self.add(path, line, "node" if manager == "nvm" else "rust", manager,
                                     f"action={manager} {action}; requested={expanded}; release channel may be floating", exact, "platform", constraint=expanded if not exact else None)
                            if not _literal(expanded):
                                self.note(path, line, f"{manager}: unresolved release {expanded}")
                    continue
                self.packages(path, line, command[match.end():], "nuget" if manager == "dotnet" else manager, action, values)
            for match in _active_matches(_PS_INSTALL, command):
                args = command[match.end():]
                tokens = _tokens(args)
                name = self._option(tokens, {"-name", "-id"})
                if not name:
                    name = next((item for item in tokens if not item.startswith("-")), "")
                version = self._option(tokens, {"-requiredversion", "-version"})
                if name:
                    manager = "winget" if match[1].lower() == "install-wingetpackage" else "psgallery"
                    self.packages(path, line, name, manager, match[1], values, version=version)
            for match in re.finditer(r"(?<![\w.-])(brew_ensure_formula|brew_ensure_cask|yuruna_service_packages)\s+([^;|]+)", command):
                manager = "brew" if match[1].startswith("brew_") else "apt"
                args = match[2] if manager == "apt" else " ".join(_tokens(match[2])[:1])
                self.packages(path, line, args, manager, match[1], values)
            for helper, name in (("Install-PowershellYamlIfMissing", "powershell-yaml"), ("Install-PSScriptAnalyzerIfMissing", "PSScriptAnalyzer")):
                if re.search(r"(?<![\w-])" + helper + r"\b", command, re.I) and not command.lower().startswith("function "):
                    self.add(path, line, name, "psgallery", f"action={helper}; version unresolved")
            if "apt-get install" in text and path.lower().endswith((".ps1", ".psm1")) and "@{" in command:
                for match in re.finditer(r"\bPackage\s*=\s*['\"]([^'\"]+)['\"]", command, re.I):
                    if _literal(match[1]):
                        self.add(path, line, match[1], "apt", "action=conditional missing-package installation table; version unresolved")
            for winget in _active_matches(re.compile(r"\bwinget\s+install\b", re.I), command):
                args = _tokens(command[winget.end():])
                name = self._option(args, {"--id", "--name"})
                if name:
                    self.packages(path, line, name, "winget", "install", values, version=self._option(args, {"--version", "-v"}))
            # Download URLs are evidence, not a resolved dependency graph. Only
            # artifact/installer endpoints become records; keys, health probes,
            # catalog metadata and directory listings do not.
            if list(_active_matches(_DOWNLOAD, command)):
                self.downloads(path, line, command, values)
            image_match = re.match(r"(?:-\s*)?(?:image|container_image|docker_image)\s*[:=]\s*['\"]?([^'\"\s,]+)", command, re.I)
            if image_match:
                for expanded in _expand(image_match[1], values):
                    self.image(path, line, expanded, "container image declaration")
            for match in _active_matches(_CONTAINER, command):
                arguments = _tokens(command[match.end():])
                value_flags = {"-v", "--volume", "--mount", "-e", "--env", "--env-file", "--name", "-p", "--publish", "--restart", "--network", "--platform", "--entrypoint", "-w", "--workdir", "-u", "--user", "--gpus", "--pull", "-l", "--label", "--device", "--add-host", "--hostname", "--memory", "--cpus", "--security-opt", "--runtime"}
                index = 0
                while index < len(arguments):
                    token = arguments[index]
                    if token.startswith("-"):
                        index += 2 if token in value_flags else 1
                        continue
                    if re.match(r"\d*[<>]|\d+>&", token) or token in {"|", "&&", "||", ";"}:
                        break
                    for expanded in _expand(token.rstrip(";"), values):
                        self.image(path, line, expanded, "container " + match[1].lower())
                    break
                if index >= len(arguments):
                    self.note(path, line, f"container {match[1]}: no literal image argument")
            optional = re.search(r"Enable-WindowsOptionalFeature\b.*?-FeatureName\s+['\"]?([\w.-]+)", command, re.I)
            if optional:
                self.add(path, line, optional[1], "windows-feature", "action=Enable-WindowsOptionalFeature; OS-provided version unresolved", kind="framework")
            if re.search(r"\b(?:dpkg\s+-i|rpm\s+-[iU]|msiexec|Add-AppxPackage|rustup-init|dotnet-install|helm_install|Save-UbuntuServerImage)\b", command, re.I):
                self.note(path, line, f"installer/action requires source or artifact resolution: {command[:240]}")
            if re.search(r"\bdotnet-install\.(?:sh|ps1)\b", command, re.I) and not _DOWNLOAD.search(command):
                args = _tokens(command)
                release = self._option(args, {"--version", "-version"})
                channel = self._option(args, {"--channel", "-channel"})
                exact = release if release and _literal(release) and re.fullmatch(r"\d+\.\d+\.\d+", release) else None
                self.add(path, line, "dotnet-sdk", "dotnet", "action=dotnet-install; selected release/channel is not resolved at generation", exact, "framework", constraint=release or channel)
            if re.search(r"\brustup-init\b", command) and "--default-toolchain" in command and not _DOWNLOAD.search(command):
                requested = self._option(_tokens(command), {"--default-toolchain"})
                if requested:
                    for expanded in _expand(requested, values):
                        exact = expanded if _literal(expanded) and re.fullmatch(r"\d+\.\d+\.\d+", expanded) else None
                        self.add(path, line, "rust", "rustup", "action=rustup-init --default-toolchain; compiler/toolchain declaration", exact, "platform", constraint=expanded if not exact else None)
            if "Save-UbuntuServerImage" in command and not command.lower().startswith("function "):
                codename = self._option(_tokens(command), {"-releasecodename"})
                self.add(path, line, "ubuntu-server-image", "download", "action=Save-UbuntuServerImage; selected daily/release image not retrieved", kind="platform", bucket="guests", constraint=codename)

    @staticmethod
    def _option(tokens: list[str], flags: set[str]) -> str | None:
        for index, token in enumerate(tokens):
            if token.lower() in flags and index + 1 < len(tokens):
                return tokens[index + 1].strip("'\",")
            for flag in flags:
                if token.lower().startswith(flag + "="):
                    return token[len(flag) + 1:]
        return None

    def _seed_packages(self, path: str, text: str):
        lines = text.splitlines()
        active_indent = None
        for number, raw in enumerate(lines, 1):
            if not raw.strip():
                continue
            indent = len(raw) - len(raw.lstrip())
            declaration = re.match(r"\s*packages:\s*(.*)", raw)
            if declaration:
                active_indent = indent
                inline = declaration[1].strip()
                if inline.startswith("["):
                    for item in inline.strip("[]").split(","):
                        name = item.strip(" '\"")
                        if _literal(name):
                            self.add(path, number, name, "apt", "action=cloud-init packages; version unresolved", bucket="guests")
                continue
            if active_indent is not None:
                if indent <= active_indent:
                    active_indent = None
                else:
                    entry = re.match(r"\s*-\s*(.+)", raw)
                    if entry:
                        value = entry[1].strip(" '\"")
                        if value.startswith("["):
                            pair = [item.strip(" '\"") for item in value.strip("[]").split(",")]
                            if pair and _literal(pair[0]):
                                self.add(path, number, pair[0], "apt", "action=cloud-init package/version tuple", pair[1] if len(pair) > 1 and _literal(pair[1]) else None, bucket="guests")
                        elif _literal(value) and re.fullmatch(r"[\w.+:=@-]+", value):
                            name, version = _package(value, "apt")
                            self.add(path, number, name, "apt", "action=cloud-init packages; OS package dependency resolution deferred", version, bucket="guests")
                        else:
                            self.note(path, number, f"unparsed cloud-init package declaration {value}")
            if re.match(r"\s*install-server:\s*true\b", raw, re.I):
                self.add(path, number, "openssh-server", "apt", "action=autoinstall ssh.install-server; version unresolved", bucket="guests")

    def image(self, path: str, line: int, reference: str, action: str, scope: str = "runtime"):
        if not _literal(reference):
            self.note(path, line, f"{action}: unresolved image reference {reference}")
            return
        if reference in {"scratch", "null", "none"} or reference.startswith(("http:", "https:")):
            return
        hashes = []
        constraint = None
        name = reference
        if "@sha256:" in reference:
            name, digest = reference.split("@sha256:", 1)
            if re.fullmatch(r"[a-fA-F0-9]{64}", digest):
                hashes = [{"alg": "SHA-256", "content": digest.lower()}]
        elif ":" in reference.rsplit("/", 1)[-1]:
            name, tag = reference.rsplit(":", 1)
            constraint = tag
        self.add(path, line, name, "oci", f"action={action}; reference={reference}; tags may move; transitive image contents unresolved", None, "container", scope, bucket="guests", hashes=hashes, constraint=constraint)

    def downloads(self, path: str, line: int, command: str, values: dict[str, list[str]]):
        if re.search(r"(?:-o|-O|--output)\s+/dev/null\b", command):
            return
        if not re.search(r"(?:\.(?:sh|ps1|deb|rpm|msi|exe|zip|tgz|tar|iso|img|qcow2|vhd)\b|-o\b|--output\b|-OutFile\b|-Destination\b|\|\s*(?:sudo\s+)?(?:bash|sh)\b|Save-(?:CachedHttpUri|YurunaImage))", command, re.I):
            return
        candidates = [match.group() for match in _URL.finditer(command)]
        for match in re.finditer(r"(?:-Uri|-Source|-SourceUrl|-SourceUri)\s+([^\s]+)", command, re.I):
            candidates.append(match[1].strip("'\""))
        for token in _tokens(command):
            if _VARIABLE.fullmatch(token):
                candidates.append(token)
        found = False
        for candidate in sorted(set(candidates)):
            for url in _expand(candidate, values):
                if not url.startswith(("http://", "https://")):
                    continue
                clean = url.split("${", 1)[0].rstrip(";,)")
                try:
                    parts = urlsplit(clean)
                except ValueError:
                    self.note(path, line, f"download URL cannot be resolved as a literal URL: {url}")
                    continue
                filename = parts.path.rsplit("/", 1)[-1]
                release_asset = "/releases/download/" in parts.path and filename and not filename.endswith((".sha256", ".asc", ".sig", ".txt"))
                if not release_asset and not re.search(r"\.(?:sh|ps1|deb|rpm|msi|exe|msix|appx|msixbundle|appxbundle|zip|tar(?:\.(?:gz|xz|bz2))?|tgz|iso|img|qcow2|vhdx?)$|^(?:rustup-init|get-helm-[\d]+|kubectl)$", filename, re.I):
                    continue
                if filename.endswith((".asc", ".gpg")):
                    continue
                found = True
                name = filename
                version = None
                kind = "application"
                hashes = []
                if "github.com/" in parts.netloc + parts.path or "githubusercontent.com" in parts.netloc:
                    segments = parts.path.strip("/").split("/")
                    if len(segments) >= 2:
                        name = "/".join(segments[:2])
                    release = re.search(r"/(?:releases/download/|[^/]+/)(v?\d+(?:\.\d+){1,3}(?:[-+][\w.-]+)?)/", parts.path)
                    if release:
                        version = release[1].removeprefix("v")
                else:
                    pinned = re.search(r"(?:^|[^\d])(\d+\.\d+\.\d+(?:[-+][\w.]+)?)(?:[^\d]|$)", filename)
                    if pinned:
                        version = pinned[1]
                if "dot.net" in parts.netloc:
                    name = "dotnet-install"
                elif "static.rust-lang.org" in parts.netloc and filename == "rustup-init":
                    name = "rustup-init"
                    rustup_version = re.search(r"/archive/(\d+\.\d+\.\d+)/", parts.path)
                    if rustup_version:
                        version = rustup_version[1]
                elif "go.dev" in parts.netloc and filename.startswith("go"):
                    name = "go"
                elif "cloud-images.ubuntu.com" in parts.netloc or "releases.ubuntu.com" in parts.netloc:
                    name, kind = "ubuntu-server-image", "platform"
                elif "amazonlinux" in clean or "al2023" in clean:
                    name, kind = "amazon-linux-image", "platform"
                elif filename.endswith((".iso", ".img", ".qcow2", ".vhd", ".vhdx")):
                    kind = "platform"
                # Match the Homebrew installer's explicitly paired commit/hash.
                # Do not attach an unrelated checksum found elsewhere in a file.
                if name == "Homebrew/install":
                    digests = values.get("homebrew_install_sha256", [])
                    hashes = [{"alg": "SHA-256", "content": digest.lower()} for digest in digests if re.fullmatch(r"[a-fA-F0-9]{64}", digest)]
                    commits = values.get("homebrew_install_commit", [])
                    if commits and commits[0] in clean:
                        version = commits[0]
                detail = f"action=downloaded provisioning artifact; source={url}; installed payload dependencies unresolved"
                if not version:
                    detail += "; artifact version unresolved or floating"
                bucket, _ = _target(path)
                if kind == "platform":
                    bucket = "guests"
                self.add(path, line, name, "download", detail, version, kind, bucket=bucket, hashes=hashes)
                if not _literal(url):
                    self.note(path, line, f"download URL contains unresolved expressions: {url}")
        if not found and re.search(r"(?:-o\b|--output\b|-OutFile\b|-Destination\b|\|\s*(?:sudo\s+)?(?:bash|sh)\b|Save-(?:CachedHttpUri|YurunaImage))", command, re.I):
            self.note(path, line, f"download action has no literal software-artifact URL: {command[:200]}")

    def result(self) -> dict:
        result = {"hosts": [], "guests": [], "coverage": sorted(self.coverage, key=lambda n: (n["path"], n["line"], n["detail"]))}
        for key in sorted(self.records):
            record = self.records[key]
            record["evidence"].sort(key=lambda item: (item["path"], item["line"], item["detail"]))
            record["hashes"].sort(key=lambda item: (item["alg"], item["content"]))
            result[key[0]].append(record)
        return result


# --- REGION: Public API
def collect_provisioning(files: dict[str, bytes], repo_name: str) -> dict:
    """Return hosts, guests and coverage notes from the supplied source bytes.

    Records represent installation declarations and conditional alternatives,
    not observed machines. Exact version information is retained when present;
    no network lookup or transitive dependency resolution is performed.
    """
    selected = {path.replace("\\", "/"): data for path, data in files.items() if _eligible(path.replace("\\", "/"))}
    collector = _Collector(repo_name)
    common = {}
    for path, data in sorted(selected.items()):
        if PurePosixPath(path).name == "yuruna-versions.sh":
            common.update(_bindings(_without_comments(data.decode("utf-8", errors="replace"))))
    for path, data in sorted(selected.items()):
        text = data.decode("utf-8", errors="replace")
        if "\ufffd" in text:
            collector.note(path, 1, "source is not valid UTF-8; some installer declarations may be unavailable", "unparsed")
        collector.scan(path, text, common)
    return collector.result()
