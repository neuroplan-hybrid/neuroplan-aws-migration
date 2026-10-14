# ROSA Grafana-managed alerts → existing On-Prem Alertmanager

Uses ROSA Thanos UID ag16e60k8yzggd. Does not install a second Alertmanager.
Does not change existing Prometheus/Blackbox rules, SMTP, receivers, notification policies,
datasources, DB/ROSA/network configuration, or restart services.

## Prerequisites
- Run on Monitoring VM as root (sudo python3).
- Existing Grafana server-admin login in organization 1, entered interactively.
  Credentials remain in process memory; never paste them into chat or Git.
- Grafana datasource Receive Grafana Alerts AND Alerting Settings forwarding enabled.
- Grafana endpoint is the already confirmed local VM address http://192.168.14.73:3000.
- The existing Alertmanager SMTP receiver must support resolved notifications if a recovery email is required.

## Workflow
1. Copy this directory to /tmp/grafana-alerting on the VM.
2. `sudo python3 /tmp/grafana-alerting/apply_rules.py test-fire`
   Creates only a clearly labelled notification test rule, vector(1).
   No actual service failure is injected. Check Alerting state and actual firing email.
3. `sudo python3 /tmp/grafana-alerting/apply_rules.py test-resolve`
   Changes only that test rule to vector(0). Verify Normal/Resolved and recovery email.
   Missing recovery email is not proof of failed forwarding: check send_resolved in the existing receiver.
4. `sudo python3 /tmp/grafana-alerting/apply_rules.py remove-test`
   Removes only the owned test UID/file.
5. `sudo python3 /tmp/grafana-alerting/apply_rules.py install`
   Adds three operating rules after actual Grafana query prechecks pass.

Initial rule thresholds are explicit starting points, not measured SLOs:
- Discovered Backend scrape target UP=0 for 1 minute (critical).
- Backend Ready count below Deployment desired replicas for 2 minutes (critical).
- 5-minute HTTP 5xx ratio >5% sustained for 5 minutes (warning).
  Low request counts can produce large error ratios; refine after traffic review.

Queries with absent/error data are not forced to healthy. Grafana NoData/Error can notify.
Reduce uses default strict semantics by omitting settings; explicit settings.mode=strict
is not supported by the server's serialized reduce model. Query A AND the full A/B/C
expression pipeline are checked before any provisioning file is changed.
If an already-owned test hit this serialization error, update these files and run
`sudo python3 /tmp/grafana-alerting/apply_rules.py test-retry` to update that same test.
Monitoring VM failure and expired Thanos token are limits of this centralized evaluation path.
Global external forwarding includes all Grafana-managed alerts, as already enabled in UI.
Do not also configure a duplicate external contact point for the same rules.

## Safety and verification
JSON contains rule groups only, no contacts/policy changes. Prechecks reject missing numeric
query values and UID conflicts before import. SQLite online backup is stored under root-private
/var/backups/neuroplan-grafana before-rosa-alerts-* directories.
Files are hot-reloaded through the authenticated Grafana Admin API.
Never automatically restore grafana.db while Grafana runs.
Local static/mock tests are not proof of actual Grafana import, evaluation or email delivery.
