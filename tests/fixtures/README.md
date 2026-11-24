# Test fixtures

`rc4-d2d441b-install-tree.tar.gz`: the REAL installable tree of release candidate RC4 (`git archive d2d441b install.sh uninstall.sh src contrib`,
version 0.2.0). Used by `tests/t_upgrade.sh` to prove RC4 -> Final upgrade, config/intent preservation and rollback against the genuine
old installer and files, not against a synthetic copy. The RC4 archives themselves must not be used as releases (D11).

Note: site-specific names and addresses inside this archive (default exit nodes, subnets, host names) were replaced by neutral values before publication; no code was changed.
