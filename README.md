# Mouse-Movement-Macro

R6 (:+ PowerShell/WPF customer application and a review-only copy of the owner key-manager UI.

## Files

- `R6-Plus-DualButton.ps1` — customer application.
- `Owner-Key-Manager-REVIEW-ONLY.ps1` — owner-manager code for review only. Its production private signing key has been removed, so it cannot create real customer keys.

## Run R6 (:+

From PowerShell on Windows:

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File .\R6-Plus-DualButton.ps1
```

The real owner key manager is intentionally kept off GitHub. It contains the private signing key used to issue licenses.

R6 (:+ checks the signed `revoked-licenses.r6r` manifest from this repository while it is running. After terminating a key in the private owner manager, publish the updated manifest to this repository so customer sessions can receive the revocation.
