# Copilot Cost Management API - verified contract

Source: Microsoft Learn, published 2026-10-15.
learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/cost-management/overview
Docs source (raw markdown): github.com/MicrosoftDocs/m365copilot-docs/tree/main/docs/api/admin-settings/cost-management

Root: https://graph.microsoft.com/beta/copilot/costManagement

## Permissions (delegated; hidden - NOT in the portal permission picker)

| Permission | Use |
| --- | --- |
| CopilotCostManagement.Read.All | getTenantCreditBalance (also supports app-only) |
| CopilotCostManagement-Policy.Read.All | Read policies, service settings, alerts, recipients |
| CopilotCostManagement-Policy.ReadWrite.All | Create/update/delete policies, service settings, alerts, recipients |
| CopilotCostManagement-Assignment.Read.All | Read a policy group audience |
| CopilotCostManagement-Assignment.ReadWrite.All | Add/remove a policy group audience |
| CopilotCostManagement-UserData.Read.All | User balance diagnostics |

Consent must be granted through a direct admin-consent URL. The
"App registrations > API permissions > Grant admin consent" button does not
support hidden permissions. A redirect containing admin_consent=True does NOT
guarantee consent applied - verify with GET /spendingPolicies.

Directory roles: Global Administrator or Billing Administrator to CREATE a
policy. AI Administrator and License Administrator can edit but not create.

## Create policy - POST /spendingPolicies

Required: displayName, periodLimit, perUserLimit, serviceSettings.
Optional: billingMethods, assignedGroups.
Do NOT send: status, or any audit property. Audience type is fixed at creation.
Returns 201 with Location and ETag headers. New policies are created DISABLED.

    {
      "@odata.type": "#microsoft.graph.selectedGroupsSpendingPolicy",
      "displayName": "Pilot teams monthly cap",
      "periodLimit": {
        "@odata.type": "#microsoft.graph.limitedCostManagementQuantity",
        "value": 10000,
        "unit": "copilotCredit"
      },
      "perUserLimit": {
        "@odata.type": "#microsoft.graph.limitedCostManagementQuantity",
        "value": 500,
        "unit": "copilotCredit"
      },
      "billingMethods": "prepaidCredits",
      "serviceSettings": [
        { "serviceId": "cowork", "state": "enabled" }
      ]
    }

"All users" audience  -> "@odata.type": "#microsoft.graph.allUsersSpendingPolicy"
"No limit"            -> { "@odata.type": "#microsoft.graph.unlimitedCostManagementQuantity",
                           "unit": "copilotCredit" }     (no "value" property)

value: 0 means "no consumption permitted" and is DISTINCT from unlimited.

## Property renames vs. the pre-publication guesses

| Old (wrong) | New (correct) |
| --- | --- |
| name | displayName |
| monthlyCreditLimit (number) | periodLimit (costManagementQuantity object) |
| userMonthlyCreditLimit (number) | perUserLimit (costManagementQuantity object) |
| isMonthlyCreditLimitEnabled | removed - use the unlimited derived type |
| thresholdPercentage | thresholds[].value + percentage @odata.type |

## Alerts - PATCH /spendingPolicies/{id}/emailThresholdSettings

Addressed as the policy's emailThresholdSettings; at most one per policy.
PATCH creates or updates. DELETE turns alerting off without removing recipients.
Configure AFTER creating the policy - it cannot be inlined in the create payload.

    {
      "isEnabled": true,
      "thresholds": [
        { "@odata.type": "#microsoft.graph.percentageCostManagementAlertThreshold",
          "value": 80 }
      ]
    }

Derived threshold types:
  #microsoft.graph.percentageCostManagementAlertThreshold   (value 1-100)
  #microsoft.graph.absoluteCostManagementAlertThreshold     (credit amount)
"value" is a Double.

Documented sequence:
  1. POST   /spendingPolicies                         -> capture id AND ETag
  2. PATCH  .../emailThresholdSettings                -> { "isEnabled": false, "thresholds": [...] }
  3. POST   .../emailThresholdSettings/recipients/$ref-> one call per recipient
  4. PATCH  .../emailThresholdSettings                -> { "isEnabled": true }
At least one recipient is required while alerting is enabled.

## Recipients - POST .../emailThresholdSettings/recipients/$ref

Body:    { "@odata.id": "https://graph.microsoft.com/v1.0/users/{userId}" }
Headers: Content-Type: application/json
         If-Match: <ETag of the PARENT spending policy>     <-- REQUIRED
Returns: 204 No Content plus an advanced ETag header.
A reference that does not resolve to a tenant user is refused with
400 alertRecipientNotFound.

## Service settings

serviceSettings is REQUIRED INLINE on create. The standalone
POST /spendingPolicies/{id}/serviceSettings route exists for later additions,
but a create call without serviceSettings fails validation.

    { "serviceId": "cowork", "state": "enabled" }

## Operational constraints

- $top does NOT work on GET /spendingPolicies. Omit it.
- Follow @odata.nextLink verbatim; never construct continuation tokens.
- Strict rate limits: send requests serially, honour Retry-After on 429.
- getTenantCreditBalance: the internal preview guide writes it with parentheses,
  Learn writes it without. If one returns 404, try the other.

## Known gap

A separate USER-LEVEL alert threshold has no equivalent in the published
costManagementAlertSetting schema - thresholds[] is a flat collection evaluated
against the policy limit. The admin centre UI exposes this option, so it is
either an unpublished property or not yet in beta. Keep the validation rule that
hard-errors a user-level alert request when no per-user limit is configured, and
re-check the schema before wiring a payload for it.