#!/usr/bin/env python3
"""Packed NAR cache for this fork's disposable experimental CI runners.

The authenticated GitHub cache repository/ref is the trust boundary, not a hash
stored beside a NAR. Never enable this importer for pull-request merge refs,
self-hosted runners, or an untrusted cache backend. Hashes detect corruption.
No daemon configuration or persistent trusted keys/users are changed.

Usage: binary-cache.py key|save|restore SCOPE EXPECTED_JSON
Expected JSON: {system, runner, roots: {name: outputPath}, derivations: {name: drv}}
Roots come from the current checkout's Nix evaluation, never cached metadata.
Restore also requires CACHE_RESTORED_KEY and GH_TOKEN (actions: read).
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


REPOSITORY = "EfeDurmaz16/mpp-sdk"
REF = "refs/heads/experiment/nix-ci"
WORKFLOW = ".github/workflows/nix-experiment.yml"
STORE = re.compile(r"/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+")
SHA256 = re.compile(r"[0-9a-f]{64}")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def output(*args):
    return run(*args, stdout=subprocess.PIPE, text=True).stdout.strip()


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def paths(values):
    require(isinstance(values, list) and values and len(values) == len(set(values)),
            "Empty or duplicated store paths")
    require(all(isinstance(p, str) and STORE.fullmatch(p) and not p.endswith(".drv")
                for p in values), "Expected complete output store paths")
    return sorted(values)


def evaluated_outputs(value):
    # Nix 2.35 emits the version-4 wrapper and store basenames. Earlier versions
    # emitted a direct derivation map with absolute output paths.
    if "version" in value:
        require(value["version"] == 4, "Unsupported Nix derivation JSON version")
        derivations = value["derivations"]
    else:
        derivations = value
    require(isinstance(derivations, dict) and derivations, "Missing evaluated derivations")
    evaluated = set()
    for derivation in derivations.values():
        for output_info in derivation["outputs"].values():
            path = output_info.get("path")
            if path is not None:
                require(isinstance(path, str), "Invalid evaluated output path")
                evaluated.add(path if path.startswith("/nix/store/") else "/nix/store/" + path)
    return set(paths(list(evaluated)))


def read_expected(path):
    expected = json.loads(path.read_text())
    require(expected.get("system") in ("aarch64-darwin", "x86_64-linux"), "Invalid cache system")
    require(isinstance(expected.get("runner"), str)
            and re.fullmatch(r"[A-Za-z0-9_.-]+", expected["runner"]), "Invalid runner label")
    require(isinstance(expected.get("roots"), dict) and expected["roots"], "Missing current roots")
    paths(list(expected["roots"].values()))
    require(isinstance(expected.get("derivations"), dict) and expected["derivations"],
            "Missing current derivations")
    require(all(isinstance(p, str) and STORE.fullmatch(p) and p.endswith(".drv")
                for p in expected["derivations"].values()), "Invalid current derivations")
    # Confirm expected output paths against current derivations before using sudo.
    derivations = json.loads(output("nix", "derivation", "show", *expected["derivations"].values()))
    evaluated = evaluated_outputs(derivations)
    require(set(expected["roots"].values()) <= evaluated,
            "Current roots are not outputs of the current evaluated derivations")
    return expected


def context():
    require(os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
            "Packed cache is restricted to disposable GitHub-hosted runners")
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY
            and os.environ.get("GITHUB_REF") == REF,
            "Packed cache is restricted to the authorized fork and experiment branch")
    require(os.environ.get("GITHUB_EVENT_NAME") in ("push", "workflow_dispatch"),
            "Pull request cache import is forbidden")
    require(os.environ.get("GITHUB_SERVER_URL") == "https://github.com",
            "Unexpected GitHub server")
    return {key: os.environ[key] for key in
            ("GITHUB_REPOSITORY", "GITHUB_REF", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA")}


def api(endpoint):
    token = os.environ.get("GH_TOKEN", "")
    require(bool(token), "GitHub cache provenance needs GH_TOKEN with actions: read")
    request = urllib.request.Request("https://api.github.com/repos/" + REPOSITORY + endpoint,
        headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def provenance(key, producer):
    query = urllib.parse.urlencode({"key": key, "ref": REF, "per_page": 100})
    caches = api("/actions/caches?" + query)["actions_caches"]
    require(any(c.get("key") == key and c.get("ref") == REF for c in caches),
            "Restored cache was not authenticated on the expected repository/ref")
    require(producer.get("GITHUB_REPOSITORY") == REPOSITORY and producer.get("GITHUB_REF") == REF,
            "Cache producer repository/ref mismatch")
    require(re.fullmatch(r"[0-9]+", str(producer.get("GITHUB_RUN_ID", "")))
            and re.fullmatch(r"[0-9]+", str(producer.get("GITHUB_RUN_ATTEMPT", ""))),
            "Invalid producer run identity")
    attempt = api(f"/actions/runs/{producer['GITHUB_RUN_ID']}/attempts/{producer['GITHUB_RUN_ATTEMPT']}")
    require(attempt.get("repository", {}).get("full_name") == REPOSITORY
            and attempt.get("head_branch") == "experiment/nix-ci"
            and attempt.get("head_sha") == producer.get("GITHUB_SHA")
            and attempt.get("path") == WORKFLOW
            and attempt.get("event") in ("push", "workflow_dispatch"),
            "Cache producer is not this fork's experimental workflow")


def files(directory):
    require(not directory.is_symlink(), "Cache directory cannot be a symlink")
    result = {}
    for path in directory.rglob("*"):
        mode = path.lstat().st_mode
        require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), "Non-regular cache entry")
        if stat.S_ISREG(mode) and path.name != "manifest.json":
            result[path.relative_to(directory).as_posix()] = digest(path)
    return result


def narinfos_for_path(directory, path, closure):
    filename = Path(path).name[:32] + ".narinfo"
    fields = {}
    for line in (directory / filename).read_text().splitlines():
        name, separator, value = line.partition(": ")
        require(bool(separator), "Malformed narinfo")
        if name != "Sig":
            require(name not in fields, "Duplicated narinfo field")
            fields[name] = value
    require(fields.get("StorePath") == path, "Narinfo store path mismatch")
    url = fields.get("URL", "")
    require(re.fullmatch(r"nar/[A-Za-z0-9._-]+\.nar\.(zst|xz|bz2)", url),
            "Narinfo URL must be a local compressed NAR")
    references = ["/nix/store/" + name for name in fields.get("References", "").split()]
    if references:
        paths(references)
    require(set(references) <= set(closure), "Narinfo reference is outside recorded closure")
    return {"url": url, "references": references}


def narinfos(directory, closure):
    return {path: narinfos_for_path(directory, path, closure) for path in closure}


def key(scope, expected):
    version = output("nix", "--version")
    lock = digest(Path("flake.lock"))
    identity = {"format": 1, "scope": scope, "expected": expected, "nix": version, "lock": lock}
    prefix = f"nix-packed-v1-{scope}-{expected['runner']}-{expected['system']}-{lock[:16]}-"
    fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return prefix + fingerprint, prefix


def github_output(**values):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            for name, value in values.items():
                stream.write(f"{name.replace('_', '-')}={value}\n")


def public_narinfo(path):
    request = urllib.request.Request("https://cache.nixos.org/" + Path(path).name[:32] + ".narinfo",
                                     method="GET")
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            data = response.read(1024 * 1024 + 1)
            if response.status == 200 and len(data) <= 1024 * 1024:
                return data.decode("utf-8")
    except (urllib.error.URLError, TimeoutError):
        # An outage keeps the payload, rather than damaging the private cache.
        pass
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("key", "save", "restore"))
    parser.add_argument("scope")
    parser.add_argument("expected", type=Path)
    args = parser.parse_args()
    require(re.fullmatch(r"[a-z0-9-]{1,40}", args.scope), "Invalid cache scope")
    producer = context()
    expected = read_expected(args.expected)
    primary, prefix = key(args.scope, expected)
    directory = Path(".nix-work/binary-cache") / args.scope
    if args.mode == "key":
        # Remove stale workspace state before actions/cache can restore a directory.
        require(not directory.is_symlink(), "Cache directory cannot be a symlink")
        if directory.exists():
            shutil.rmtree(directory)
        github_output(primary_key=primary, restore_prefix=prefix, cache_path=str(directory))
        return
    if args.mode == "save":
        require(os.environ.get("CACHE_PRIMARY_KEY") == primary, "Save must use the original evaluated key")
        roots = paths(list(expected["roots"].values()))
        closure = paths(output("nix-store", "--query", "--requisites", *roots).splitlines())
        if directory.exists():
            require(not directory.is_symlink(), "Cache directory cannot be a symlink")
            shutil.rmtree(directory)
        directory.mkdir(parents=True)
        # Seed public narinfos so the target already knows their reference graph.
        # nix copy then compresses private outputs only. Empty public metadata
        # would make --no-recursive export reject missing references (#12835).
        public = []
        with ThreadPoolExecutor(max_workers=16) as executor:
            for path, data in zip(closure, executor.map(public_narinfo, closure)):
                if data is None:
                    continue
                candidate = directory / (Path(path).name[:32] + ".narinfo")
                candidate.write_text(data)
                try:
                    # Validate references and local URLs before seeding nix copy.
                    narinfos_for_path(directory, path, closure)
                    require("Sig: cache.nixos.org-1:" in data, "Unsigned public narinfo")
                except ValueError:
                    candidate.unlink()
                    continue
                public.append(path)
        run("nix", "copy", "--to", directory.absolute().as_uri() + "?compression=zstd", *roots)
        narinfos(directory, closure)
        write_json(directory / "metadata.json", {"format": 1, "scope": args.scope,
            "primary_key": primary, "system": expected["system"], "producer": producer,
            "roots": roots, "closure": closure, "public": public})
        write_json(directory / "manifest.json", files(directory))
        print(f"Packed {len(roots)} roots, {len(closure) - len(public)} private NARs; {len(public)} public payloads omitted")
        return
    restored = os.environ.get("CACHE_RESTORED_KEY", "")
    if not restored:
        print("Packed cache miss; normal Nix build will realize current roots")
        return
    require(restored.startswith(prefix), "Restored key belongs to an incompatible cache namespace")
    manifest_path = directory / "manifest.json"
    require(stat.S_ISREG(manifest_path.lstat().st_mode), "Manifest must be a regular file")
    manifest = json.loads(manifest_path.read_text())
    require(isinstance(manifest, dict) and all(isinstance(v, str) and SHA256.fullmatch(v)
                for v in manifest.values()), "Invalid cache manifest")
    require(files(directory) == manifest, "Packed cache file list or SHA256 mismatch")
    metadata = json.loads((directory / "metadata.json").read_text())
    require(metadata.get("format") == 1 and metadata.get("scope") == args.scope
            and metadata.get("system") == expected["system"] and metadata.get("primary_key") == restored,
            "Cache format/scope/system/key mismatch")
    provenance(restored, metadata["producer"])
    closure = paths(metadata["closure"])
    cached_roots = paths(metadata["roots"])
    public = metadata["public"]
    require(isinstance(public, list) and len(public) == len(set(public)) and set(public) <= set(closure),
            "Invalid public path set")
    require(set(cached_roots) <= set(closure), "Cached roots omitted from closure")
    info = narinfos(directory, closure)
    selected = set(expected["roots"].values()) & set(cached_roots)
    if not selected:
        print("No compatible current output roots; rebuild without importing cached outputs")
        return
    needed = set()
    pending = list(selected)
    while pending:
        path = pending.pop()
        if path not in needed:
            needed.add(path)
            pending.extend(info[path]["references"])
    signed_public = sorted(needed & set(public))
    if signed_public:
        # Keep signature verification for public dependencies, without sudo.
        run("nix", "copy", "--from", "https://cache.nixos.org", *signed_public)
    private = sorted(needed - set(public))
    for path in private:
        require((directory / info[path]["url"]).is_file(), "Missing private NAR payload")
    if private:
        binary = shutil.which("nix")
        require(binary is not None and str(Path(binary).resolve(strict=True)).startswith("/nix/store/"),
                "Privileged importer must be the installed Nix binary")
        binary = str(Path(binary).parent.resolve(strict=True) / "nix")
        # Only this validated local cache and compatible output closure get a
        # privileged copy. Public signatures and daemon trust remain unchanged.
        run("sudo", "-n", "--", binary, "copy", "--no-check-sigs", "--no-recursive",
            "--from", directory.absolute().as_uri(), *private)
    actual = paths(output("nix-store", "--query", "--requisites", *sorted(selected)).splitlines())
    require(set(actual) == needed, "Imported closure differs from the validated reference graph")
    print(f"Imported {len(selected)} compatible current roots / {len(needed)} paths from {restored}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"binary-cache: {error}", file=sys.stderr)
        sys.exit(1)
