#!/usr/bin/env python3
"""Fetch and verify portable SeedVR2 TensorRT ONNX artifacts from Hugging Face."""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

from huggingface_hub import hf_hub_download

EXPECTED = (
    "vae_encoder_5f_tile512.onnx",
    "vae_encoder_21f_tile512.onnx",
    "vae_decoder_tile_512_5f.onnx",
    "vae_decoder_tile_256_21f.onnx",
)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def truthy(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_checksums(path: Path) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            continue
        digest, filename = parts
        filename = filename.lstrip("*")
        # Accept both portable basename entries and the absolute paths used by
        # the first canonical upload; only the basename matters locally.
        checksums[Path(filename).name] = digest.lower()
    return checksums


def parse_manifest(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def download(
    *, repo_id: str, repo_type: str, revision: str, token: str | None,
    filename: str, local_dir: Path, force: bool = False,
) -> Path:
    path = hf_hub_download(
        repo_id=repo_id,
        repo_type=repo_type,
        revision=revision,
        token=token,
        filename=filename,
        local_dir=str(local_dir),
        force_download=force,
    )
    return Path(path)


def main() -> int:
    repo_id = env("HF_ONNX_REPO", "markwelshboyx/seedvr2-studio-onnx")
    repo_type = env("HF_ONNX_REPO_TYPE", "dataset")
    revision = env("HF_ONNX_REVISION", "main")
    local_dir = Path(env("ONNX_DATA", "/workspace/seedvr2-studio/tensorrt-onnx"))
    token = env("HF_ONNX_TOKEN") or env("HF_TOKEN") or env("HUGGING_FACE_HUB_TOKEN") or None
    expected_upstream = env("STUDIO_UPSTREAM_REF")
    allow_mismatch = truthy(env("HF_ONNX_ALLOW_MISMATCH", "false"))

    if not repo_id:
        print("HF_ONNX_REPO is empty; portable ONNX download disabled.")
        return 2

    local_dir.mkdir(parents=True, exist_ok=True)
    print(f"Portable ONNX repo : {repo_id}")
    print(f"Repo type          : {repo_type}")
    print(f"Revision           : {revision}")
    print(f"Local cache        : {local_dir}")
    print(f"Expected upstream  : {expected_upstream or '<not pinned>'}")
    print(f"Authentication     : {'token available' if token else 'no token found'}")

    try:
        checksum_path = download(
            repo_id=repo_id, repo_type=repo_type, revision=revision, token=token,
            filename="SHA256SUMS", local_dir=local_dir,
        )
    except Exception as exc:
        print(f"ERROR: could not fetch SHA256SUMS from {repo_id}: {exc}", file=sys.stderr)
        return 1

    checksums = parse_checksums(checksum_path)
    missing_hashes = [name for name in EXPECTED if name not in checksums]
    if missing_hashes:
        print("ERROR: SHA256SUMS is missing expected files: " + ", ".join(missing_hashes), file=sys.stderr)
        return 1

    manifest_path: Path | None = None
    try:
        manifest_path = download(
            repo_id=repo_id, repo_type=repo_type, revision=revision, token=token,
            filename="manifest.txt", local_dir=local_dir,
        )
    except Exception as exc:
        if expected_upstream and not allow_mismatch:
            print(
                f"ERROR: manifest.txt is required to validate upstream compatibility: {exc}",
                file=sys.stderr,
            )
            return 1
        print(f"[warn] manifest.txt could not be fetched: {exc}")

    if manifest_path is not None:
        manifest = parse_manifest(manifest_path)
        artifact_upstream = manifest.get("upstream_ref", "")
        if expected_upstream:
            if not artifact_upstream:
                if not allow_mismatch:
                    print("ERROR: manifest.txt has no upstream_ref entry", file=sys.stderr)
                    return 1
                print("[warn] manifest.txt has no upstream_ref entry; mismatch override enabled")
            elif artifact_upstream != expected_upstream:
                message = (
                    "Portable ONNX upstream mismatch: "
                    f"image={expected_upstream}, artifacts={artifact_upstream}"
                )
                if not allow_mismatch:
                    print(f"ERROR: {message}", file=sys.stderr)
                    print("ERROR: Set HF_ONNX_ALLOW_MISMATCH=true only if this is intentional.", file=sys.stderr)
                    return 1
                print(f"[warn] {message}; mismatch override enabled")
            else:
                print(f"[ok] manifest upstream_ref matches image ({artifact_upstream})")

    for name in EXPECTED:
        expected = checksums[name]
        candidate = local_dir / name
        if candidate.exists():
            actual = sha256(candidate)
            if actual == expected:
                print(f"[ok] cached {name} ({actual[:12]}...)")
                continue
            print(f"[warn] checksum mismatch for cached {name}; downloading a clean copy")
            candidate.unlink()

        try:
            downloaded = download(
                repo_id=repo_id, repo_type=repo_type, revision=revision, token=token,
                filename=name, local_dir=local_dir,
            )
        except Exception as exc:
            print(f"ERROR: could not download {name}: {exc}", file=sys.stderr)
            return 1

        actual = sha256(downloaded)
        if actual != expected:
            print(f"[warn] first download checksum mismatch for {name}; forcing one retry", file=sys.stderr)
            downloaded.unlink(missing_ok=True)
            try:
                downloaded = download(
                    repo_id=repo_id, repo_type=repo_type, revision=revision, token=token,
                    filename=name, local_dir=local_dir, force=True,
                )
            except Exception as exc:
                print(f"ERROR: forced retry failed for {name}: {exc}", file=sys.stderr)
                return 1
            actual = sha256(downloaded)

        if actual != expected:
            print(
                f"ERROR: SHA256 mismatch for {name}: expected {expected}, got {actual}",
                file=sys.stderr,
            )
            return 1
        print(f"[ok] verified {name} ({actual[:12]}...)")

    print("All portable ONNX artifacts are present and verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
