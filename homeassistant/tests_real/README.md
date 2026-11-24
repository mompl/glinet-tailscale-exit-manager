# Real Home Assistant tests (requirement D)

These tests load the integration into the REAL Home Assistant core (via `pytest-homeassistant-custom-component`) with a real
config flow, entity registry, service calls and coordinator. The router is simulated by the fake rpcd endpoint in front of the
REAL rpcd plugin and the REAL tsem controller (mock backend). They do NOT replace the install on the Home Assistant.

    python3 -m venv ~/ha-venv && ~/ha-venv/bin/pip install pytest-homeassistant-custom-component "pycares==4.5.0"
    ~/ha-venv/bin/python -m pytest -c homeassistant/pytest.ini homeassistant/tests_real -q -p no:cacheprovider

Python and Home Assistant versions follow the installed `pytest-homeassistant-custom-component` release.
