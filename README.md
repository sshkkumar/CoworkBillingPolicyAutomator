# Cowork Billing Policy Automator

Bulk-create Microsoft Copilot **Cowork spending (billing) policies** from a CSV file.

A PowerShell module does the work; a small WinForms GUI wraps it for anyone who would
rather not use the console. **Nothing is ever written to your tenant unless you explicitly
ask for it** — every run is validate-only until you pass `-Commit` (or press *Commit* in
the GUI).

---

## Contents

| File | Purpose |
|---|---|
| `CoworkBillingPolicy.psd1` / `.psm1` | Module manifest and loader |
| `Cowork.Config.ps1` | Config loading, logging, shared state |
| `Cowork.GraphClient.ps1` | Auth + the single Graph request wrapper (retry, paging, `-WhatIfPayload`) |
| `Cowork.Lookups.ps1` | Tenant balance, policies, group/user/service resolution |
| `Cowork.CsvSchema.ps1` | CSV schema, parsing, **all request payload builders** |
| `Cowork.Validation.ps1` | Every validation rule |
| `Cowork.Creation.ps1` | Multi-step creation, rollback, read-back verification |
| `Cowork.Deletion.ps1` | Exact-match, ETag-protected policy deletion |
| `Cowork.Public.ps1` | `Test-CoworkPolicyFile`, `Invoke-CoworkPolicyImport`, reporting |
| `Start-CoworkPolicyGui.ps1` | WinForms front end |
| `config.json` | Graph base URI, scopes, limits, behaviour |
| `services.json` | Friendly agent/service name → `serviceId` |
| `policies-template.csv` | Blank header row |
| `policies-sample.csv` | Four ready-to-run example policies |
| `policies-invalid-sample.csv` | One row per validation failure, for demos and testing |
| `CoworkBillingPolicy.Tests.ps1` | Pester tests (fully offline, Graph is mocked) |

> All files must stay in the **same folder** — the module dot-sources its parts and reads
> `config.json` / `services.json` from next to `CoworkBillingPolicy.psm1`.

---

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+
- `Microsoft.Graph.Authentication`:
  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```
  Only needed for anything that touches the tenant. It is intentionally *not* a declared
  `RequiredModules` entry, so the module still imports without it and offline work
  (`Import-CoworkPolicyCsv`, `Invoke-CoworkPolicyImport -Offline`, the Pester suite) runs on a
  machine with no Graph SDK at all.
- An account with permission to manage Copilot spending policies
- For the tests only: `Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0`

---

## Quick start

```powershell
Import-Module .\CoworkBillingPolicy.psd1 -Force

# 1. Sign in (interactive, delegated)
Connect-CoworkPolicy

# 2. Confirm the API base path is right for your tenant
Test-CoworkPolicyConnection -AutoDiscover

# 3. Validate the sample - reads your tenant, writes nothing
Invoke-CoworkPolicyImport -Path .\policies-sample.csv

# 4. See the exact calls that would be made, still writing nothing
Invoke-CoworkPolicyImport -Path .\policies-sample.csv -Commit -WhatIfPayload
Get-CoworkPayloadLog

# 5. Create the policies for real
Invoke-CoworkPolicyImport -Path .\policies-sample.csv -Commit

# Delete one policy safely: preview first (no DELETE is sent)
Remove-CoworkSpendingPolicy -Name 'Cowork Standard Policy'
# Commit the deletion; -Force skips the confirmation prompt
Remove-CoworkSpendingPolicy -Name 'Cowork Standard Policy' -Commit -Force
# An exact id can be used instead of a name
Remove-CoworkSpendingPolicy -Id '<policy-id>' -Commit

# Get all the policies
Get-CoworkSpendingPolicy -Refresh | Select-Object id, displayName

```

GUI:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\Start-CoworkPolicyGui.ps1
```

---

## Configuring the API base path

The internal API document lists endpoint **paths** (`/spendingPolicies`,
`/getTenantCreditBalance()`, `/userBalances/{userId}`, …) but not the root segment they
hang off. The tool composes it from `config.json`:

```
{GraphBaseUri}/{ApiVersion}/{BillingRootPath}
https://graph.microsoft.com  /beta  /copilot/billing
```

`copilot/billing` is a **documented best guess**. If it is wrong you get a clear HTTP 404
message naming the exact key to change — no code edits are needed.

```powershell
# Probe every candidate and report which one works
Test-CoworkPolicyConnection -AutoDiscover

# Probe and write the working value back into config.json
Test-CoworkPolicyConnection -AutoDiscover -Apply

# Or set it directly
Set-CoworkBillingRootPath -BillingRootPath 'admin/copilot/billing'
```

Group and user lookups deliberately use the stable `v1.0` endpoint (`DirectoryBaseUri`).

### Scopes

`config.json` → `Scopes` defaults to `Group.Read.All` and `User.Read.All` (needed to
validate groups and alert recipients). If the consent prompt or an HTTP 403 says a
Copilot/billing scope is missing, add it to that array and run `Connect-CoworkPolicy -Force`.

---

## Service IDs

There is no "list services" endpoint, so `services.json` maps friendly names to
`serviceId` values. **Verify these against your tenant before committing:**

```powershell
# Reads serviceSettings from existing policies and prints a ready-to-paste block
Get-CoworkServiceCatalog -FromExistingPolicies
```

The published API uses `cowork` for the Copilot Cowork service; this is the default
mapping in the shipped `services.json`. Other service IDs should still be verified
against your tenant before use. A raw GUID in the CSV is always accepted and passed
through unmapped, so you are never blocked by the mapping file.

---

## CSV reference

One row = one policy. Multi-value cells are separated with `;`.

| Column | Required | Allowed values |
|---|---|---|
| `PolicyName` | yes | Text, **10 characters minimum**, unique |
| `AssignmentType` | yes | `AllUsers` or `Groups` |
| `Groups` | when `Groups` | `;`-separated group display names or object ids |
| `Services` | yes | `;`-separated names from `services.json`, e.g. `Copilot Cowork` |
| `MonthlySpendingLimitType` | yes | `NoLimit` or `Limited` |
| `MonthlySpendingLimitCredits` | when `Limited` | Whole number, **min 4000**, 10000+ recommended |
| `UserMonthlyBudgetLimitType` | yes | `NoLimit` or `Limited` |
| `UserMonthlyBudgetLimitCredits` | when `Limited` | Whole number, **min 2000**, 7000+ recommended |
| `AlertEmails` | when an alert is set | `;`-separated tenant user UPNs / emails |
| `PolicyAlertThresholdType` | no | `Percent` or `Credits` |
| `PolicyAlertThresholdValue` | with type | Number |
| `UserAlertThresholdType` | no | `Percent` or `Credits` |
| `UserAlertThresholdValue` | with type | Number |

Enum values are matched case- and punctuation-insensitively (`all users`, `NO_LIMIT`,
`no limit` all work). Credit values tolerate thousands separators (`"12,000"`).

Example:

```csv
PolicyName,AssignmentType,Groups,Services,MonthlySpendingLimitType,MonthlySpendingLimitCredits,UserMonthlyBudgetLimitType,UserMonthlyBudgetLimitCredits,AlertEmails,PolicyAlertThresholdType,PolicyAlertThresholdValue,UserAlertThresholdType,UserAlertThresholdValue
Cowork Standard Policy,AllUsers,,Copilot Cowork,Limited,12000,Limited,7000,billing-admins@contoso.com,Percent,80,Percent,75
Cowork Engineering Pilot,Groups,Engineering Team;Platform Engineering,Copilot Cowork;Copilot Studio,Limited,25000,Limited,8000,finops@contoso.com;ops-lead@contoso.com,Percent,75,Credits,6000
```

---

## Validation rules

### Errors — the row is rejected and nothing is created

| # | Rule |
|---|---|
| 1 | `PolicyName` present and at least 10 characters |
| 2 | `PolicyName` unique within the file |
| 3 | `PolicyName` not already used by an existing policy in the tenant |
| 4 | `AssignmentType` is `AllUsers` or `Groups` |
| 5 | `Groups` is non-empty when `AssignmentType=Groups` |
| 6 | Every group exists in the tenant; an ambiguous display name is rejected (use the object id) |
| 7 | `Services` non-empty and every entry resolves via `services.json` or is a GUID |
| 8 | Limit types valid; credits present when `Limited`, and `Limited` credits are numeric |
| 9 | `MonthlySpendingLimitCredits` ≥ **4000** |
| 10 | `UserMonthlyBudgetLimitCredits` ≥ **2000** |
| 11 | `UserMonthlyBudgetLimitCredits` ≤ `MonthlySpendingLimitCredits` |
| 12 | Existing + new policy credit commitments ≤ tenant balance from `getTenantCreditBalance()` |
| 13 | `Percent` thresholds are 1–100 |
| 14 | `Credits` thresholds do not exceed the limit they are measured against |
| 15 | `Percent` requires the matching limit to be `Limited` |
| 16 | **A user alert requires `UserMonthlyBudgetLimitType=Limited`** — otherwise the row is rejected with an explicit message |
| 17 | A threshold requires at least one resolvable `AlertEmails` recipient, and recipients require a threshold |
| 18 | Threshold type and value must be supplied together |

### Warnings — advisory only, the row still runs

- Policy limit ≥ 4000 but < 10000 → 10000+ recommended
- User budget ≥ 2000 but < 7000 → 7000+ recommended
- Committed credits above 80% of the tenant balance
- Alert threshold above 90% of its limit — little time to react
- A limited policy with no alert configured at all
- `Groups` supplied for an `AllUsers` policy (ignored)
- Credits supplied alongside `NoLimit` (ignored)

---

## What happens on `-Commit`

Per valid row:

1. `POST   /spendingPolicies` — `@odata.type` is `allUsersSpendingPolicy` or `selectedGroupsSpendingPolicy`
2. `POST   /spendingPolicies/{id}/microsoft.graph.selectedGroupsSpendingPolicy/assignedGroups/$ref` — per group
3. `POST   /spendingPolicies/{id}/serviceSettings` — per service
4. `PATCH  /spendingPolicies/{id}/emailThresholdSettings`
5. `POST   /spendingPolicies/{id}/emailThresholdSettings/recipients/$ref` — per recipient

**If any step after step 1 fails, the policy is deleted** (`DELETE /spendingPolicies/{id}`)
so your tenant is never left with a half-configured policy. The failing step and the
rollback outcome are recorded in the report. A failed rollback is reported loudly so you
can delete it manually.

Afterwards the policy is **read back** and diffed against the CSV intent (name, limit,
groups, services, recipients). Any mismatch appears as a warning — this is how a
silently-ignored property surfaces immediately instead of weeks later.

Every run writes:

- `reports\cowork-policy-results-<timestamp>.csv` — per-row status, errors, warnings, steps, rollback
- `logs\cowork-<timestamp>.log` — full transcript

---

## Endpoint coverage

| Area | Endpoint | Used by |
|---|---|---|
| Tenant balance | `GET /getTenantCreditBalance()` | tenant ceiling validation |
| User balances | `GET /userBalances/{userId}`, `/serviceBalances`, `/serviceBalances/{serviceId}` | `Get-CoworkUserBalance` |
| Policies | `GET`/`POST` `/spendingPolicies`, `GET`/`PATCH`/`DELETE` `/spendingPolicies/{id}` | list, create, verify, rollback, exact-match deletion |
| Group assignments | `GET`/`POST $ref`/`DELETE $ref` `.../assignedGroups` | assign and verify groups |
| Alert settings | `GET`/`PATCH`/`DELETE` `.../emailThresholdSettings` | thresholds |
| Alert recipients | `GET`/`POST $ref`/`DELETE $ref` `.../recipients` | recipients |
| Service settings | `GET`/`POST` `/serviceSettings`, `GET`/`PATCH` `/serviceSettings/{serviceId}` | agent selection |
| Directory | `GET v1.0/groups`, `GET v1.0/users/{upn}` | validate groups and recipients |

---

## Payload property names

The API document gives paths, not request bodies. **Every body is built in
`Cowork.CsvSchema.ps1`** so a wrong property name is a one-line fix in one file:

| Builder | Properties sent |
|---|---|
| `New-CoworkSpendingPolicyPayload` | `@odata.type`, `displayName`, `periodLimit`, `perUserLimit`, `billingMethods`, `serviceSettings` |
| `New-CoworkServiceSettingPayload` | `serviceId`, `state` |
| `New-CoworkEmailThresholdPayload` | `thresholds`, `isEnabled` |
| `New-CoworkDirectoryRefPayload` | `@odata.id` |

Confirm them against your tenant before a bulk run:

```powershell
Invoke-CoworkPolicyImport -Path .\policies-sample.csv -Commit -WhatIfPayload
Get-CoworkPayloadLog | Format-List
```

Nothing is sent in this mode — it prints the method, full URL, and JSON body of every
write call.

---

## Command reference

| Command | Description |
|---|---|
| `Connect-CoworkPolicy [-Force]` | Interactive delegated sign-in |
| `Disconnect-CoworkPolicy` | Sign out, clear caches |
| `Test-CoworkPolicyConnection [-AutoDiscover] [-Apply]` | Verify / discover the billing root path |
| `Set-CoworkBillingRootPath -BillingRootPath <s>` | Persist a new base path to `config.json` |
| `Test-CoworkPolicyFile -Path <csv> [-Offline]` | Validate only (alias of a non-commit import) |
| `Invoke-CoworkPolicyImport -Path <csv> [-Commit] [-WhatIfPayload] [-Offline] [-ReportPath <p>]` | Main workflow |
| `Remove-CoworkSpendingPolicy -Id <id> [-Commit] [-Force]` | Preview or delete one policy by exact id |
| `Remove-CoworkSpendingPolicy -Name <name> [-Commit] [-Force]` | Preview or delete one policy by exact name |
| `New-CoworkPolicyTemplate -Path <csv>` | Write a blank template |
| `Get-CoworkTenantCreditBalance` | Tenant credit balance |
| `Get-CoworkSpendingPolicy [-Id <id>]` | List or get policies |
| `Get-CoworkUserBalance -UserId <upn> [-ServiceBalances] [-ServiceId <s>]` | User balances |
| `Get-CoworkServiceCatalog [-FromExistingPolicies]` | Service mapping / discovery |
| `Get-CoworkPayloadLog` | Calls captured in `-WhatIfPayload` mode |
| `Get-CoworkCsvColumn` | CSV schema reference |

`-Offline` skips all tenant lookups so you can check a file's structure before signing in.
It cannot be combined with `-Commit`.

---

## GUI

1. **Sign in to Microsoft Graph** — account and tenant appear next to the button
2. **Test API endpoint** — probes every candidate path and offers to save the working one
3. Pick a CSV (or **New template**), then **Validate**
4. Review the grid — red = invalid/failed, amber = valid with warnings, blue = ready, green = created.
   Double-click any row for full detail
5. **Preview calls** shows the exact requests without sending them
6. **Commit valid rows** stays disabled until a validation pass succeeds on the *current*
   file, and always asks for confirmation
7. **Export report** saves the results CSV anywhere you like
8. **Manage existing policies** refreshes the tenant list; select one to preview deletion, then use **Delete selected** and confirm the warning to delete it. The GUI previews first and passes `-Force` only after your explicit confirmation.

<img width="1741" height="1155" alt="image" src="https://github.com/user-attachments/assets/5ea7882a-7b41-4c86-ae53-d04e763021cc" />

---

## Tests

```powershell
Invoke-Pester .\CoworkBillingPolicy.Tests.ps1
```

All Graph traffic is mocked at `Invoke-CoworkGraphRequest`, so the suite runs offline with
no tenant and no sign-in. It covers CSV parsing, every validation rule, the payload
builders, and the creation/rollback paths.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `HTTP 404` on every call | `BillingRootPath` is wrong — run `Test-CoworkPolicyConnection -AutoDiscover -Apply` |
| `HTTP 403` | Add the missing scope to `config.json` → `Scopes`, then `Connect-CoworkPolicy -Force` |
| `Unknown service '…'` | Add it to `services.json`, or run `Get-CoworkServiceCatalog -FromExistingPolicies` |
| `Group '…' is ambiguous` | Two groups share that display name — use the object id in the CSV |
| Tenant-ceiling checks skipped | `getTenantCreditBalance()` returned an unrecognized shape; inspect `(Get-CoworkTenantCreditBalance).Raw` and add the property name to `Get-CoworkFirstNumericProperty` |
| Verification warnings after create | A payload property name is likely wrong — see **Payload property names** |
| GUI will not start | Run with `-STA`: `powershell -ExecutionPolicy Bypass -STA -File .\Start-CoworkPolicyGui.ps1` |
