# php2shell.sh — patch PHP2Shell (CVE-2026-109618, CVE-2026-109619) on Debian/Ubuntu with PHP from Surý

[Русская версия](README.ru.md)

`php2shell.sh` checks and patches **every installed PHP version** on a Debian/Ubuntu server against PHP2Shell — two critical pre-auth remote code execution vulnerabilities in the PHP core (CVE-2026-109618, CVE-2026-109619, CVSS v4.0 9.2, fixes released on 21 October 2026).

It is built for Debian/Ubuntu servers with PHP from the Ondřej Surý repository, where one machine often hosts 2–12 PHP versions side by side, and it handles the cases where a "successful" `apt upgrade` still leaves the server vulnerable. On servers with the [HestiaCP](https://hestiacp.com/) panel it also checks the panel's own PHP (`hestia-php`) and snapshots all HestiaCP sites before and after the patch.

Version **1.0** (2026-10-23). Used in production on 6 Ubuntu servers with HestiaCP: 50 of 50 PHP installations patched, ~140 sites checked before and after with no change in responses, 1–2 seconds of downtime per php-fpm restart.

## Why not just `apt upgrade`?

| Pitfall | What happens | How the script handles it |
|---|---|---|
| Renamed ondrej PPA | On older servers apt has silently refused the PHP repository index since 2022 because the `Label` field changed. `apt upgrade` says "already the newest version" while packages are years old | Refreshes the repository index and stops if the PHP index was not updated, instead of reporting a fake success. Manual fix: `apt-get update --allow-releaseinfo-change-label` |
| Version number proves nothing | For branches 5.6–8.1 the PHP version stays the same, only the package revision changes (7.4.33-30 → 7.4.33-31) | Looks for the CVE IDs in the changelog of `phpX.Y-common` |
| Many PHP versions per server | A forgotten 5.6 with a single site exposes the whole server | Updates all installed `php*` packages at once |
| No restart, no fix | Running php-fpm pools keep the old code in memory | Restarts every `phpX.Y-fpm`, Apache and the panel |
| The panel has its own PHP | HestiaCP ships a separate `hestia-php` package | Checks and updates it separately |
| Repository errors don't stop apt | On a signature error apt falls back to the old index and "successfully" does nothing | Stops before installing if the PHP repository index was not refreshed |

## Requirements

- Debian 11/12/13 or Ubuntu 20.04/22.04/24.04/26.04, root or sudo.
- PHP from the Ondřej Surý repository (`deb.sury.org` / `ppa:ondrej/php`).
- At least 1 GB of free space in `/var`.

**Not supported:** CentOS/RHEL/AlmaLinux, cPanel, Plesk, BitrixVM. Note that no vendor ships a fixed PHP build for CentOS 7 — migrate, build PHP yourself or use commercial extended support.

## Usage

Download `php2shell-kit.tar.gz` from [Releases](../../releases), copy it to the server and run:

```bash
tar xzf php2shell-kit.tar.gz && cd php2shell-kit
sudo ./php2shell.sh check          # check only, changes nothing
sudo ./php2shell.sh patch          # patch, asks for confirmation
sudo ./php2shell.sh patch --yes    # no prompt, for automation
sudo ./php2shell.sh sites          # HestiaCP site response snapshot only
```

Recommended order: `check` → `patch` on one server → verify sites → the rest of the servers → `check` again.

### Modes

| Mode | What it does |
|---|---|
| `check` | For every PHP version, looks for the CVE fix in the `phpX.Y-common` changelog; shows the `hestia-php` version |
| `patch` | Site snapshot → `apt-get update` → upgrade of installed `php*` and `hestia-php` only → restart of php-fpm, Apache, panel → site check and comparison |
| `sites` | Snapshot of HTTP status codes of all HestiaCP sites |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | everything is patched |
| `1` | vulnerable versions remain |
| `2` | error or aborted |

### Example output (`check` after patching)

The script's messages are in Russian (`ИТОГ: всё пропатчено` = "RESULT: everything patched"):

```text
php2shell.sh 1.0 (2026-10-23) | server.example.com | Ubuntu 22.04.5 LTS | amd64 | режим: check
  PHP 7.4  1:7.4.33-31+ubuntu22.04.1+deb.sury.org+1     OK
  PHP 8.2  8.2.35-1+ubuntu22.04.1+deb.sury.org+1        OK
  PHP 8.3  8.3.36-1+ubuntu22.04.1+deb.sury.org+1        OK
  hestia-php 8.5.12-1+ubuntu22.04                        PHP 8.5.12 (cli)
ИТОГ: всё пропатчено
```

## Safety

- Installs new versions of already installed packages only; PHP config files are not overwritten.
- Stops before installing if the PHP repository index was not updated.
- Refuses to run twice at the same time; checks free disk space.
- Logs everything to `/var/log/php2shell/`: main log, apt log, site snapshots before and after.

## FAQ

**Will sites go down?** No. The upgrade runs in the background for 15–30 minutes; sites pause for 1–2 seconds while php-fpm restarts.

**A version is still `УЯЗВИМ` (vulnerable) after patching.** There is no fixed build of that version for your OS or architecture. Move its sites to PHP 8.2+ and remove it.

**"PHP repository was not updated".** Usually an expired key or no network. Look for `E:` lines in the output.

**"Sites: CHANGES DETECTED".** Check the listed domains manually. A site that returned 500 before the patch will return 500 after it.

**How do I roll back?** You don't need to: the upgrade stays within the same PHP version (e.g. 8.2.33 → 8.2.35).

**After patching:** look for signs of compromise since 17 October 2026 — crashed PHP workers, web shells, new cron jobs and SSH keys.

## More

- Step-by-step guide (RU): https://citypeople.ru/services-and-prices/advice/hestiacp/php2shell.html
- Write-up with all the pitfalls (RU): https://citypeople.ru/news-and-articles/php2shell-hestiacp-kak-zakryt.html

## Author

[City People](https://citypeople.ru/) — web studio, Perm, Russia. Server maintenance and PHP support: https://citypeople.ru/contacts.html

## License

<!-- TODO: choose a license (MIT suggested) and add the LICENSE file -->
See [LICENSE](LICENSE).

## Disclaimer

The script is provided as is. Run `check` first and test `patch` on one server before rolling it out. Always keep backups.
