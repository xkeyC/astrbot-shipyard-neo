"""Unit tests for IPython environment loading."""

import pytest


pytestmark = pytest.mark.unit


def test_load_env_file_decodes_shell_quoted_values(tmp_path, monkeypatch):
    from app.components import ipython

    env_file = tmp_path / ".bay_env.sh"
    env_file.write_text(
        "export http_proxy='http://user:p$ &\\@proxy:7890'\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(ipython, "WORKSPACE_ROOT", tmp_path)

    assert ipython._load_env_file()["http_proxy"] == "http://user:p$ &\\@proxy:7890"


def test_load_env_file_keeps_quoted_profile_env_spaces(tmp_path, monkeypatch):
    from app.components import ipython

    env_file = tmp_path / ".bay_env.sh"
    env_file.write_text("export GREETING='hello world'\n", encoding="utf-8")
    monkeypatch.setattr(ipython, "WORKSPACE_ROOT", tmp_path)

    assert ipython._load_env_file()["GREETING"] == "hello world"


def test_load_runtime_env_preserves_profile_proxy_over_container_env(tmp_path, monkeypatch):
    from app.components import ipython

    env_file = tmp_path / ".bay_env.sh"
    env_file.write_text("export http_proxy='http://profile:7890'\n", encoding="utf-8")
    monkeypatch.setattr(ipython, "WORKSPACE_ROOT", tmp_path)
    monkeypatch.setenv("http_proxy", "http://runtime:7890")

    assert ipython._load_runtime_env()["http_proxy"] == "http://profile:7890"
