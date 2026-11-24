"""Real Home Assistant test environment (pytest-homeassistant-custom-component): the integration is loaded by the REAL
Home Assistant core, with a real config flow, real entity registry, real service calls and a real DataUpdateCoordinator.
Only the router is simulated, by the fake rpcd endpoint in front of the REAL rpcd plugin and the REAL tsem controller
(mock backend). Not part of the plain `tests/run.sh` run: it needs the venv described in tests_real/README.md."""
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
HA_DIR = os.path.abspath(os.path.join(HERE, ".."))
REPO = os.path.abspath(os.path.join(HA_DIR, ".."))
sys.path.insert(0, HA_DIR)  # custom_components.tsem becomes importable
sys.path.insert(0, os.path.join(HA_DIR, "tests"))  # fake_ubus

pytest_plugins = ["pytest_homeassistant_custom_component"]


@pytest.fixture(autouse=True)
def auto_enable_custom_integrations(enable_custom_integrations):
    yield


# Note: pycares 5.x starts a permanent daemon thread (`_run_safe_shutdown_loop`) that the harness's strict thread check
# flags in the first test. The tested Home Assistant release pins an older pycares: install it with `pip install "pycares==4.5.0"`.


@pytest.fixture(autouse=True)
def only_localhost_sockets(socket_enabled):
    """The harness blocks all sockets; the fake router listens on 127.0.0.1, so allow exactly that and nothing else."""
    from pytest_socket import socket_allow_hosts
    socket_allow_hosts(["127.0.0.1"], allow_unix_socket=True)
    yield


@pytest.fixture
def tsem_env(tmp_path, monkeypatch):
    """The environment of the REAL controller (mock backend), exactly like tests/lib.sh t_setup."""
    env = {
        "ROOT": REPO, "SH": "sh", "TSEM_BACKEND": "mock", "TSEM_LIBDIR": os.path.join(REPO, "src/usr/lib/tsem"),
        "TSEM_STATE_DIR": str(tmp_path / "state"), "TSEM_RUN_DIR": str(tmp_path / "run"), "TSEM_MOCK_DIR": str(tmp_path / "mock"),
        "TSEM_CONF": str(tmp_path / "none.conf"), "TSEM_PRIMARY": "100.64.0.10", "TSEM_SECONDARY": "100.64.0.11",
        "TSEM_SYSLOG": "0", "TSEM_SET_TICK_DELAY": "0", "TSEM_NOW": "1790000000", "TSEM_LOCK_TIMEOUT": "10",
        "TSEM_BIN": os.path.join(REPO, "src/usr/sbin/tsem"),
    }
    for d in ("state", "run", "mock"):
        (tmp_path / d).mkdir()
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    # the plugin parses JSON with OpenWrt's `jsonfilter`; the test stub of the repo stands in for it (as in tests/lib.sh)
    monkeypatch.setenv("PATH", os.path.join(REPO, "tests/stubs") + os.pathsep + os.environ["PATH"])
    return env


@pytest.fixture
def router(tsem_env):
    import fake_ubus  # needs ROOT in the environment (tsem_env sets it)
    r = fake_ubus.FakeRouter({"admin": ("pw", "tsem-write"), "reader": ("pw", "tsem-read")})
    yield r
    r.stop()
