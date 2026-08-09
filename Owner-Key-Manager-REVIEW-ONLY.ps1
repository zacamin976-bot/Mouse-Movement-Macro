$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('R6DarkResizableForm' -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class R6DarkResizableForm : Form
{
    protected override void WndProc(ref Message message)
    {
        base.WndProc(ref message);
        if (message.Msg != 0x84 || WindowState != FormWindowState.Normal) return;
        const int grip = 8;
        Point point = PointToClient(Cursor.Position);
        bool left = point.X <= grip;
        bool right = point.X >= ClientSize.Width - grip;
        bool top = point.Y <= grip;
        bool bottom = point.Y >= ClientSize.Height - grip;
        if (left && top) message.Result = (IntPtr)13;
        else if (right && top) message.Result = (IntPtr)14;
        else if (left && bottom) message.Result = (IntPtr)16;
        else if (right && bottom) message.Result = (IntPtr)17;
        else if (left) message.Result = (IntPtr)10;
        else if (right) message.Result = (IntPtr)11;
        else if (top) message.Result = (IntPtr)12;
        else if (bottom) message.Result = (IntPtr)15;
    }
}

public static class R6DarkWindowNative
{
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", EntryPoint="SetProcessDpiAwarenessContext")] private static extern bool SetProcessDpiAwarenessContext(IntPtr context);

    public static void EnableBestDpiAwareness()
    {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }

    public static void EnableDoubleBuffer(Control control)
    {
        try {
            typeof(Control).GetProperty("DoubleBuffered", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
                .SetValue(control, true, null);
        } catch { }
    }
}
'@
}

[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$embeddedPrivateKey = @"
<RSAKeyValue><Modulus>REVIEW_ONLY_PRIVATE_KEY_REMOVED</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>
"@
$ownerDataDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Codex\R6-Owner-Data'
[IO.Directory]::CreateDirectory($ownerDataDirectory) | Out-Null
$ledgerPath = Join-Path $ownerDataDirectory 'issued-licenses.csv'
$deletedLicenseIdsPath = Join-Path $ownerDataDirectory 'deleted-license-ids.txt'
$revocationManifestPath = Join-Path $ownerDataDirectory 'revoked-licenses.r6r'

# Import portable ledgers only when creating the stable owner ledger for the first time.
$legacyLedgerCandidates = @(
    (Join-Path $PSScriptRoot 'Owner-Data\issued-licenses.csv'),
    (Join-Path $PSScriptRoot 'R6-OWNER-FINAL\Owner-Data\issued-licenses.csv'),
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'Owner-Data\issued-licenses.csv')
) | Select-Object -Unique
$mergedRecords = New-Object Collections.ArrayList
$knownLicenseIds = @{}
$deletedLicenseIds = @{}
$stableLedgerAlreadyExists = Test-Path -LiteralPath $ledgerPath
if (Test-Path -LiteralPath $deletedLicenseIdsPath) {
    foreach ($deletedId in @(Get-Content -LiteralPath $deletedLicenseIdsPath -Encoding UTF8)) {
        $cleanDeletedId = ([string]$deletedId).Trim().ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($cleanDeletedId)) { $deletedLicenseIds[$cleanDeletedId] = $true }
    }
}
$ledgerSources = if ($stableLedgerAlreadyExists) { @($ledgerPath) } else { @($legacyLedgerCandidates) }
foreach ($candidate in $ledgerSources) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    try {
        foreach ($record in @(Import-Csv -LiteralPath $candidate)) {
            $recordId = [string]$record.LicenseId
            $normalizedRecordId = $recordId.Trim().ToUpperInvariant()
            if ([string]::IsNullOrWhiteSpace($normalizedRecordId) -or $knownLicenseIds.ContainsKey($normalizedRecordId) -or $deletedLicenseIds.ContainsKey($normalizedRecordId)) { continue }
            $product = if ($record.PSObject.Properties.Name -contains 'Product' -and -not [string]::IsNullOrWhiteSpace($record.Product)) { $record.Product } else { 'R6 (:' }
            [void]$mergedRecords.Add([pscustomobject]@{ IssuedUtc=$record.IssuedUtc; Product=$product; CustomerName=$record.CustomerName; LicenseId=$recordId; Serial=$record.Serial })
            $knownLicenseIds[$normalizedRecordId] = $true
        }
    } catch { }
}
if ($stableLedgerAlreadyExists) {
    $tombstonesChanged = $false
    foreach ($legacyCandidate in $legacyLedgerCandidates) {
        if (-not (Test-Path -LiteralPath $legacyCandidate)) { continue }
        try {
            foreach ($legacyRecord in @(Import-Csv -LiteralPath $legacyCandidate)) {
                $legacyId = ([string]$legacyRecord.LicenseId).Trim().ToUpperInvariant()
                if (-not [string]::IsNullOrWhiteSpace($legacyId) -and -not $knownLicenseIds.ContainsKey($legacyId) -and -not $deletedLicenseIds.ContainsKey($legacyId)) {
                    $deletedLicenseIds[$legacyId] = $true
                    $tombstonesChanged = $true
                }
            }
        } catch { }
    }
    if ($tombstonesChanged) {
        [IO.File]::WriteAllLines($deletedLicenseIdsPath, @($deletedLicenseIds.Keys | Sort-Object), [Text.UTF8Encoding]::new($false))
    }
}
if ($mergedRecords.Count -gt 0) {
    $mergedRecords | Select-Object IssuedUtc,Product,CustomerName,LicenseId,Serial | Export-Csv -LiteralPath $ledgerPath -NoTypeInformation -Encoding UTF8
} elseif (-not (Test-Path -LiteralPath $ledgerPath)) {
    [IO.File]::WriteAllText($ledgerPath, "IssuedUtc,Product,CustomerName,LicenseId,Serial`r`n", [Text.UTF8Encoding]::new($false))
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Write-R6RevocationManifest {
    # Review copy: the production signing key is intentionally removed.
    return
    $revokedIds = @()
    if (Test-Path -LiteralPath $deletedLicenseIdsPath) {
        $revokedIds = @(Get-Content -LiteralPath $deletedLicenseIdsPath -Encoding UTF8 |
            ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique)
    }

    $payloadText = 'R6R1|' + [DateTime]::UtcNow.ToString('o') + '|' + ($revokedIds -join ',')
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payloadText)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString($embeddedPrivateKey)
        $signature = $rsa.SignData($payloadBytes, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
    } finally {
        $rsa.Dispose()
    }

    $manifest = 'R6R.' + (ConvertTo-Base64Url $payloadBytes) + '.' + (ConvertTo-Base64Url $signature)
    $temporaryPath = $revocationManifestPath + '.tmp'
    [IO.File]::WriteAllText($temporaryPath, $manifest, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $revocationManifestPath -Force | Out-Null
}

Write-R6RevocationManifest

function New-R6Serial([string]$CustomerName, [string]$Product = 'R6 (:') {
    throw 'This review copy cannot generate production keys. Keep the owner key manager private.'
    $normalized = $CustomerName.Trim().ToUpperInvariant()
    if ($normalized.Length -lt 2) { throw 'Enter a customer name containing at least two characters.' }

    $nameToken = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($normalized))
    $licenseId = [Guid]::NewGuid().ToString('N').Substring(0,16).ToUpperInvariant()
    $issued = [DateTime]::UtcNow.ToString('yyyyMMdd')
    $productMarker = if ($Product -eq 'R6 (:+') { 'R6P1' } else { 'R6L1' }
    $payloadText = "$productMarker|$nameToken|$licenseId|$issued"
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payloadText)

    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    $rsa.FromXmlString($embeddedPrivateKey)
    $signature = $rsa.SignData($payloadBytes, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'))
    $rsa.Dispose()

    $serial = 'R6.' + (ConvertTo-Base64Url $payloadBytes) + '.' + (ConvertTo-Base64Url $signature)
    [pscustomobject]@{ Product=$Product; Name=$CustomerName.Trim(); LicenseId=$licenseId; IssuedUtc=$issued; Serial=$serial }
}

function Test-R6NameAlreadyIssued([string]$CustomerName, [string]$Product = 'R6 (:') {
    if (-not (Test-Path -LiteralPath $ledgerPath)) { return $false }
    $normalized = $CustomerName.Trim().ToUpperInvariant()
    if ($normalized.Length -eq 0) { return $false }
    try {
        foreach ($issued in @(Import-Csv -LiteralPath $ledgerPath)) {
            $issuedProduct = if ($issued.PSObject.Properties.Name -contains 'Product' -and
                -not [string]::IsNullOrWhiteSpace($issued.Product)) { $issued.Product } else { 'R6 (:' }
            if ($null -ne $issued.CustomerName -and
                $issuedProduct -eq $Product -and
                $issued.CustomerName.Trim().ToUpperInvariant() -eq $normalized) {
                return $true
            }
        }
        return $false
    } catch {
        throw 'The issuance ledger could not be read. No key was generated to avoid creating a duplicate.'
    }
}

$purple = [Drawing.Color]::FromArgb(151,99,190)
$muted = [Drawing.Color]::FromArgb(184,139,215)
$field = [Drawing.Color]::FromArgb(18,10,22)

$form = New-Object R6DarkResizableForm
$form.Text = 'R6 (: Owner Key Manager'
$form.ClientSize = New-Object Drawing.Size(940,730)
$form.MinimumSize = New-Object Drawing.Size(800,640)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [Drawing.Color]::FromArgb(7,6,8)
$form.ForeColor = $purple
$form.Font = New-Object Drawing.Font('Segoe UI',15,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$form.AutoScaleMode = 'None'
$form.MaximizeBox = $true
$form.MinimizeBox = $true
$form.FormBorderStyle = 'None'
$form.Padding = New-Object Windows.Forms.Padding(1)

$topBar = New-Object Windows.Forms.Panel
$topBar.Location = New-Object Drawing.Point(1,1)
$topBar.Size = New-Object Drawing.Size(938,44)
$topBar.Anchor = 'Top,Left,Right'
$topBar.BackColor = [Drawing.Color]::FromArgb(12,10,15)
$form.Controls.Add($topBar)

$topBarTitle = New-Object Windows.Forms.Label
$topBarTitle.Text = 'R6 (: / R6 (:+  OWNER KEY MANAGER'
$topBarTitle.ForeColor = $muted
$topBarTitle.Font = New-Object Drawing.Font('Segoe UI Semibold',15,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
$topBarTitle.AutoSize = $true
$topBarTitle.Location = New-Object Drawing.Point(16,13)
$topBar.Controls.Add($topBarTitle)

$ownerMinimize = New-Object Windows.Forms.Button
$ownerMinimize.Text = '_'
$ownerMinimize.Location = New-Object Drawing.Point(801,5)
$ownerMinimize.Size = New-Object Drawing.Size(42,34)
$ownerMinimize.Anchor = 'Top,Right'
$ownerMinimize.FlatStyle = 'Flat'
$ownerMinimize.FlatAppearance.BorderSize = 0
$ownerMinimize.BackColor = [Drawing.Color]::FromArgb(24,19,29)
$ownerMinimize.ForeColor = $muted
$topBar.Controls.Add($ownerMinimize)

$ownerMaximize = New-Object Windows.Forms.Button
$ownerMaximize.Text = 'O'
$ownerMaximize.Location = New-Object Drawing.Point(847,5)
$ownerMaximize.Size = New-Object Drawing.Size(42,34)
$ownerMaximize.Anchor = 'Top,Right'
$ownerMaximize.FlatStyle = 'Flat'
$ownerMaximize.FlatAppearance.BorderSize = 0
$ownerMaximize.BackColor = [Drawing.Color]::FromArgb(24,19,29)
$ownerMaximize.ForeColor = $muted
$topBar.Controls.Add($ownerMaximize)

$ownerClose = New-Object Windows.Forms.Button
$ownerClose.Text = 'X'
$ownerClose.Location = New-Object Drawing.Point(893,5)
$ownerClose.Size = New-Object Drawing.Size(42,34)
$ownerClose.Anchor = 'Top,Right'
$ownerClose.FlatStyle = 'Flat'
$ownerClose.FlatAppearance.BorderSize = 0
$ownerClose.BackColor = [Drawing.Color]::FromArgb(24,19,29)
$ownerClose.ForeColor = $muted
$topBar.Controls.Add($ownerClose)

$dragOwnerWindow = {
    if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) {
        [void][R6DarkWindowNative]::ReleaseCapture()
        [void][R6DarkWindowNative]::SendMessage($form.Handle,0xA1,2,0)
    }
}
$topBar.Add_MouseDown($dragOwnerWindow)
$topBarTitle.Add_MouseDown($dragOwnerWindow)
$ownerMinimize.Add_Click({ $form.WindowState = 'Minimized' })
$toggleOwnerMaximize = {
    $form.WindowState = if ($form.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
}
$ownerMaximize.Add_Click($toggleOwnerMaximize)
$topBar.Add_DoubleClick($toggleOwnerMaximize)
$topBarTitle.Add_DoubleClick($toggleOwnerMaximize)
$ownerClose.Add_Click({ $form.Close() })
foreach ($button in @($ownerMinimize,$ownerMaximize,$ownerClose)) { $button.Cursor = 'Hand' }

$title = New-Object Windows.Forms.Label
$title.Text = 'R6 (: / R6 (:+ OWNER KEY MANAGER'
$title.Font = New-Object Drawing.Font('Segoe UI Semibold',24,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
$title.ForeColor = $purple
$title.AutoSize = $true
$title.Location = New-Object Drawing.Point(24,56)
$title.Visible = $false
$form.Controls.Add($title)

$warning = New-Object Windows.Forms.Label
$warning.Text = 'PRIVATE OWNER TOOL - NEVER SEND THIS FOLDER OR PRIVATE KEY TO CUSTOMERS'
$warning.ForeColor = [Drawing.Color]::White
$warning.AutoSize = $true
$warning.Location = New-Object Drawing.Point(27,60)
$form.Controls.Add($warning)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(20,88)
$tabs.Size = New-Object Drawing.Size(900,615)
$tabs.Anchor = 'Top,Bottom,Left,Right'
$tabs.Font = New-Object Drawing.Font('Segoe UI Semibold',15,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
$tabs.SizeMode = 'Fixed'
$tabs.ItemSize = New-Object Drawing.Size(235,44)
$tabs.Alignment = 'Top'
$tabs.Appearance = 'FlatButtons'
$tabs.HotTrack = $false
$form.Controls.Add($tabs)

$generatePage = New-Object Windows.Forms.TabPage
$generatePage.Text = 'R6 (: STANDARD'
$generatePage.BackColor = [Drawing.Color]::FromArgb(9,8,11)
$generatePage.ForeColor = $purple
$tabs.TabPages.Add($generatePage)

$licensesPage = New-Object Windows.Forms.TabPage
$licensesPage.Text = 'LICENSE SEARCH'
$licensesPage.BackColor = [Drawing.Color]::FromArgb(9,8,11)
$licensesPage.ForeColor = $purple

$plusPage = New-Object Windows.Forms.TabPage
$plusPage.Text = 'R6 (:+ PLUS'
$plusPage.BackColor = [Drawing.Color]::FromArgb(9,8,11)
$plusPage.ForeColor = $purple
$tabs.TabPages.Add($plusPage)
$tabs.TabPages.Add($licensesPage)

$nameLabel = New-Object Windows.Forms.Label
$nameLabel.Text = 'CUSTOMER NAME'
$nameLabel.ForeColor = $muted
$nameLabel.AutoSize = $true
$nameLabel.Location = New-Object Drawing.Point(20,20)
$generatePage.Controls.Add($nameLabel)

$nameBox = New-Object Windows.Forms.TextBox
$nameBox.Location = New-Object Drawing.Point(20,47)
$nameBox.Size = New-Object Drawing.Size(850,34)
$nameBox.BackColor = $field
$nameBox.ForeColor = $muted
$nameBox.BorderStyle = 'FixedSingle'
$nameBox.Font = New-Object Drawing.Font('Segoe UI Semibold',16,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$generatePage.Controls.Add($nameBox)

$generate = New-Object Windows.Forms.Button
$generate.Text = 'GENERATE SIGNED SERIAL'
$generate.Location = New-Object Drawing.Point(20,95)
$generate.Size = New-Object Drawing.Size(850,44)
$generate.BackColor = $purple
$generate.ForeColor = [Drawing.Color]::White
$generate.FlatStyle = 'Flat'
$generate.FlatAppearance.BorderColor = [Drawing.Color]::White
$generatePage.Controls.Add($generate)

$serialLabel = New-Object Windows.Forms.Label
$serialLabel.Text = 'SERIAL TO SEND TO CUSTOMER'
$serialLabel.ForeColor = $muted
$serialLabel.AutoSize = $true
$serialLabel.Location = New-Object Drawing.Point(20,158)
$generatePage.Controls.Add($serialLabel)

$serialBox = New-Object Windows.Forms.TextBox
$serialBox.Location = New-Object Drawing.Point(20,185)
$serialBox.Size = New-Object Drawing.Size(850,130)
$serialBox.Multiline = $true
$serialBox.ScrollBars = 'Vertical'
$serialBox.ReadOnly = $true
$serialBox.BackColor = $field
$serialBox.ForeColor = $muted
$serialBox.BorderStyle = 'FixedSingle'
$serialBox.Font = New-Object Drawing.Font('Consolas',14,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$generatePage.Controls.Add($serialBox)

$copy = New-Object Windows.Forms.Button
$copy.Text = 'Copy serial'
$copy.Location = New-Object Drawing.Point(20,330)
$copy.Size = New-Object Drawing.Size(200,40)
$copy.BackColor = $field
$copy.ForeColor = $muted
$copy.FlatStyle = 'Flat'
$copy.FlatAppearance.BorderColor = [Drawing.Color]::White
$generatePage.Controls.Add($copy)

$clear = New-Object Windows.Forms.Button
$clear.Text = 'Clear / New customer'
$clear.Location = New-Object Drawing.Point(240,330)
$clear.Size = New-Object Drawing.Size(200,40)
$clear.BackColor = $field
$clear.ForeColor = $muted
$clear.FlatStyle = 'Flat'
$clear.FlatAppearance.BorderColor = [Drawing.Color]::White
$generatePage.Controls.Add($clear)

$status = New-Object Windows.Forms.Label
$status.Text = 'Waiting for a customer name.'
$status.ForeColor = $muted
$status.AutoSize = $false
$status.Size = New-Object Drawing.Size(850,55)
$status.Location = New-Object Drawing.Point(20,385)
$generatePage.Controls.Add($status)

$plusTitle = New-Object Windows.Forms.Label
$plusTitle.Text = 'R6 (:+ CUSTOMER LICENSE'
$plusTitle.ForeColor = $purple
$plusTitle.Font = New-Object Drawing.Font('Segoe UI Semibold',17,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
$plusTitle.AutoSize = $true
$plusTitle.Location = New-Object Drawing.Point(20,16)
$plusPage.Controls.Add($plusTitle)

$plusNameLabel = New-Object Windows.Forms.Label
$plusNameLabel.Text = 'PLUS CUSTOMER NAME'
$plusNameLabel.ForeColor = $muted
$plusNameLabel.AutoSize = $true
$plusNameLabel.Location = New-Object Drawing.Point(20,52)
$plusPage.Controls.Add($plusNameLabel)

$plusNameBox = New-Object Windows.Forms.TextBox
$plusNameBox.Location = New-Object Drawing.Point(20,79)
$plusNameBox.Size = New-Object Drawing.Size(850,34)
$plusNameBox.BackColor = $field
$plusNameBox.ForeColor = $muted
$plusNameBox.BorderStyle = 'FixedSingle'
$plusNameBox.Font = New-Object Drawing.Font('Segoe UI Semibold',16,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$plusPage.Controls.Add($plusNameBox)

$plusGenerate = New-Object Windows.Forms.Button
$plusGenerate.Text = 'GENERATE R6 (:+ SIGNED SERIAL'
$plusGenerate.Location = New-Object Drawing.Point(20,127)
$plusGenerate.Size = New-Object Drawing.Size(850,44)
$plusGenerate.BackColor = $purple
$plusGenerate.ForeColor = [Drawing.Color]::White
$plusGenerate.FlatStyle = 'Flat'
$plusGenerate.FlatAppearance.BorderColor = [Drawing.Color]::White
$plusPage.Controls.Add($plusGenerate)

$plusSerialLabel = New-Object Windows.Forms.Label
$plusSerialLabel.Text = 'PLUS SERIAL TO SEND TO CUSTOMER'
$plusSerialLabel.ForeColor = $muted
$plusSerialLabel.AutoSize = $true
$plusSerialLabel.Location = New-Object Drawing.Point(20,190)
$plusPage.Controls.Add($plusSerialLabel)

$plusSerialBox = New-Object Windows.Forms.TextBox
$plusSerialBox.Location = New-Object Drawing.Point(20,217)
$plusSerialBox.Size = New-Object Drawing.Size(850,130)
$plusSerialBox.Multiline = $true
$plusSerialBox.ScrollBars = 'Vertical'
$plusSerialBox.ReadOnly = $true
$plusSerialBox.BackColor = $field
$plusSerialBox.ForeColor = $muted
$plusSerialBox.BorderStyle = 'FixedSingle'
$plusSerialBox.Font = New-Object Drawing.Font('Consolas',14,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$plusPage.Controls.Add($plusSerialBox)

$plusCopy = New-Object Windows.Forms.Button
$plusCopy.Text = 'Copy Plus serial'
$plusCopy.Location = New-Object Drawing.Point(20,360)
$plusCopy.Size = New-Object Drawing.Size(200,40)
$plusCopy.BackColor = $field
$plusCopy.ForeColor = $muted
$plusCopy.FlatStyle = 'Flat'
$plusCopy.FlatAppearance.BorderColor = [Drawing.Color]::White
$plusPage.Controls.Add($plusCopy)

$plusClear = New-Object Windows.Forms.Button
$plusClear.Text = 'Clear / New customer'
$plusClear.Location = New-Object Drawing.Point(240,360)
$plusClear.Size = New-Object Drawing.Size(200,40)
$plusClear.BackColor = $field
$plusClear.ForeColor = $muted
$plusClear.FlatStyle = 'Flat'
$plusClear.FlatAppearance.BorderColor = [Drawing.Color]::White
$plusPage.Controls.Add($plusClear)

$plusStatus = New-Object Windows.Forms.Label
$plusStatus.Text = 'Waiting for an R6 (:+ customer name.'
$plusStatus.ForeColor = $muted
$plusStatus.AutoSize = $false
$plusStatus.Size = New-Object Drawing.Size(850,55)
$plusStatus.Location = New-Object Drawing.Point(20,417)
$plusPage.Controls.Add($plusStatus)

$searchLabel = New-Object Windows.Forms.Label
$searchLabel.Text = 'SEARCH ACCOUNTS, LICENSE IDS, OR SERIALS'
$searchLabel.ForeColor = $muted
$searchLabel.AutoSize = $true
$searchLabel.Location = New-Object Drawing.Point(18,16)
$licensesPage.Controls.Add($searchLabel)

$searchBox = New-Object Windows.Forms.TextBox
$searchBox.Location = New-Object Drawing.Point(18,43)
$searchBox.Size = New-Object Drawing.Size(525,32)
$searchBox.BackColor = $field
$searchBox.ForeColor = $muted
$searchBox.BorderStyle = 'FixedSingle'
$searchBox.Font = New-Object Drawing.Font('Segoe UI Semibold',15,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$licensesPage.Controls.Add($searchBox)

$refreshButton = New-Object Windows.Forms.Button
$refreshButton.Text = 'Refresh'
$refreshButton.Location = New-Object Drawing.Point(558,41)
$refreshButton.Size = New-Object Drawing.Size(150,36)
$refreshButton.BackColor = $field
$refreshButton.ForeColor = $muted
$refreshButton.FlatStyle = 'Flat'
$refreshButton.FlatAppearance.BorderColor = [Drawing.Color]::White
$licensesPage.Controls.Add($refreshButton)

$offlineNotice = New-Object Windows.Forms.Label
$offlineNotice.Text = 'Shows issued keys from the stable owner ledger. Offline activation status and revocation are not available.'
$offlineNotice.ForeColor = [Drawing.Color]::White
$offlineNotice.AutoSize = $false
$offlineNotice.Size = New-Object Drawing.Size(850,25)
$offlineNotice.Font = New-Object Drawing.Font('Segoe UI',14,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$offlineNotice.Location = New-Object Drawing.Point(18,87)
$licensesPage.Controls.Add($offlineNotice)

$standardHeading = New-Object Windows.Forms.Label
$standardHeading.Text = 'R6 (: STANDARD'
$standardHeading.ForeColor = $purple
$standardHeading.Font = New-Object Drawing.Font('Segoe UI Semibold',15,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
$standardHeading.AutoSize = $true
$standardHeading.Location = New-Object Drawing.Point(18,116)
$licensesPage.Controls.Add($standardHeading)

$plusHeading = New-Object Windows.Forms.Label
$plusHeading.Text = 'R6 (:+ PLUS'
$plusHeading.ForeColor = $purple
$plusHeading.Font = New-Object Drawing.Font('Segoe UI Semibold',15,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
$plusHeading.AutoSize = $true
$plusHeading.Location = New-Object Drawing.Point(377,116)
$licensesPage.Controls.Add($plusHeading)

$standardList = New-Object Windows.Forms.ListView
$standardList.Location = New-Object Drawing.Point(18,143)
$standardList.Size = New-Object Drawing.Size(335,248)
$standardList.View = 'Details'
$standardList.FullRowSelect = $true
$standardList.MultiSelect = $false
$standardList.GridLines = $true
$standardList.HideSelection = $false
$standardList.BackColor = [Drawing.Color]::Black
$standardList.ForeColor = $muted
$standardList.Font = New-Object Drawing.Font('Segoe UI',14,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
[void]$standardList.Columns.Add('Issued',78)
[void]$standardList.Columns.Add('Account',125)
[void]$standardList.Columns.Add('License ID',125)
[void]$standardList.Columns.Add('Serial key',0)
$licensesPage.Controls.Add($standardList)

$splitLine = New-Object Windows.Forms.Panel
$splitLine.Location = New-Object Drawing.Point(364,116)
$splitLine.Size = New-Object Drawing.Size(2,275)
$splitLine.BackColor = $purple
$licensesPage.Controls.Add($splitLine)

$plusList = New-Object Windows.Forms.ListView
$plusList.Location = New-Object Drawing.Point(377,143)
$plusList.Size = New-Object Drawing.Size(331,248)
$plusList.View = 'Details'
$plusList.FullRowSelect = $true
$plusList.MultiSelect = $false
$plusList.GridLines = $true
$plusList.HideSelection = $false
$plusList.BackColor = [Drawing.Color]::Black
$plusList.ForeColor = $muted
$plusList.Font = New-Object Drawing.Font('Segoe UI',14,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
[void]$plusList.Columns.Add('Issued',78)
[void]$plusList.Columns.Add('Account',125)
[void]$plusList.Columns.Add('License ID',125)
[void]$plusList.Columns.Add('Serial key',0)
$licensesPage.Controls.Add($plusList)

$copyIssuedButton = New-Object Windows.Forms.Button
$copyIssuedButton.Text = 'Copy selected serial'
$copyIssuedButton.Location = New-Object Drawing.Point(18,407)
$copyIssuedButton.Size = New-Object Drawing.Size(210,40)
$copyIssuedButton.BackColor = $field
$copyIssuedButton.ForeColor = $muted
$copyIssuedButton.FlatStyle = 'Flat'
$copyIssuedButton.FlatAppearance.BorderColor = [Drawing.Color]::White
$licensesPage.Controls.Add($copyIssuedButton)

$deleteIssuedButton = New-Object Windows.Forms.Button
$deleteIssuedButton.Text = 'Delete selected record'
$deleteIssuedButton.Location = New-Object Drawing.Point(245,407)
$deleteIssuedButton.Size = New-Object Drawing.Size(210,40)
$deleteIssuedButton.BackColor = [Drawing.Color]::FromArgb(75,20,35)
$deleteIssuedButton.ForeColor = [Drawing.Color]::White
$deleteIssuedButton.FlatStyle = 'Flat'
$deleteIssuedButton.FlatAppearance.BorderColor = [Drawing.Color]::White
$licensesPage.Controls.Add($deleteIssuedButton)

$revokeIssuedButton = New-Object Windows.Forms.Button
$revokeIssuedButton.Text = 'Terminate This MF'
$revokeIssuedButton.Location = New-Object Drawing.Point(473,407)
$revokeIssuedButton.Size = New-Object Drawing.Size(160,40)
$revokeIssuedButton.BackColor = [Drawing.Color]::FromArgb(105,32,48)
$revokeIssuedButton.ForeColor = [Drawing.Color]::White
$revokeIssuedButton.FlatStyle = 'Flat'
$revokeIssuedButton.FlatAppearance.BorderColor = [Drawing.Color]::White
$licensesPage.Controls.Add($revokeIssuedButton)

$licenseCount = New-Object Windows.Forms.Label
$licenseCount.Text = '0 issued licenses'
$licenseCount.ForeColor = $muted
$licenseCount.AutoSize = $false
$licenseCount.TextAlign = 'MiddleRight'
$licenseCount.Size = New-Object Drawing.Size(235,40)
$licenseCount.Location = New-Object Drawing.Point(650,407)
$licensesPage.Controls.Add($licenseCount)

# Responsive layout and understated animated hover treatment.
foreach ($control in @($nameBox,$generate,$serialBox,$status,$plusNameBox,$plusGenerate,$plusSerialBox,$plusStatus)) {
    $control.Anchor = 'Top,Left,Right'
}
$standardList.Anchor = 'Top,Bottom,Left'
$plusList.Anchor = 'Top,Bottom,Left,Right'
$splitLine.Anchor = 'Top,Bottom,Left'
$copyIssuedButton.Anchor = 'Bottom,Left'
$deleteIssuedButton.Anchor = 'Bottom,Left'
$revokeIssuedButton.Anchor = 'Bottom,Left'
$licenseCount.Anchor = 'Bottom,Right'
$searchBox.Anchor = 'Top,Left,Right'
$refreshButton.Anchor = 'Top,Right'

function Enable-DarkListView($list) {
    $list.OwnerDraw = $true
    $list.GridLines = $false
    $list.HeaderStyle = 'Nonclickable'
    $list.Add_DrawColumnHeader({
        $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(24,19,29))
        try { $eventArgs.Graphics.FillRectangle($brush,$eventArgs.Bounds) } finally { $brush.Dispose() }
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,$eventArgs.Header.Text,$list.Font,$eventArgs.Bounds,$muted,
            [Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis)
    }.GetNewClosure())
    $list.Add_DrawItem({
        if ($list.View -ne [Windows.Forms.View]::Details) { $eventArgs.DrawDefault = $true }
    }.GetNewClosure())
    $list.Add_DrawSubItem({
        $selected = $eventArgs.Item.Selected
        $back = if ($selected) { [Drawing.Color]::FromArgb(50,32,61) } elseif (($eventArgs.ItemIndex % 2) -eq 0) { [Drawing.Color]::FromArgb(12,10,15) } else { [Drawing.Color]::FromArgb(17,16,20) }
        $fore = if ($selected) { [Drawing.Color]::White } else { $muted }
        $brush = New-Object Drawing.SolidBrush $back
        try { $eventArgs.Graphics.FillRectangle($brush,$eventArgs.Bounds) } finally { $brush.Dispose() }
        $textBounds = New-Object Drawing.Rectangle(($eventArgs.Bounds.X+6),$eventArgs.Bounds.Y,[math]::Max(0,$eventArgs.Bounds.Width-8),$eventArgs.Bounds.Height)
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,$eventArgs.SubItem.Text,$list.Font,$textBounds,$fore,
            [Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis)
    }.GetNewClosure())
}
Enable-DarkListView $standardList
Enable-DarkListView $plusList
[R6DarkWindowNative]::EnableDoubleBuffer($form)
[R6DarkWindowNative]::EnableDoubleBuffer($tabs)
[R6DarkWindowNative]::EnableDoubleBuffer($standardList)
[R6DarkWindowNative]::EnableDoubleBuffer($plusList)

$tabs.DrawMode = 'OwnerDrawFixed'
$tabs.Padding = New-Object Drawing.Point(18,6)
$script:hoverTabIndex = -1
$tabs.Add_MouseMove({
    $newHover = -1
    for ($index=0; $index -lt $tabs.TabCount; $index++) {
        if ($tabs.GetTabRect($index).Contains($_.Location)) { $newHover = $index; break }
    }
    if ($newHover -ne $script:hoverTabIndex) { $script:hoverTabIndex = $newHover; $tabs.Invalidate() }
})
$tabs.Add_MouseLeave({ $script:hoverTabIndex = -1; $tabs.Invalidate() })
$tabs.Add_DrawItem({
    param($sender,$eventArgs)
    $selected = ($eventArgs.Index -eq $sender.SelectedIndex)
    $back = if ($selected) { [Drawing.Color]::FromArgb(50,32,61) } elseif ($eventArgs.Index -eq $script:hoverTabIndex) { [Drawing.Color]::FromArgb(33,23,40) } else { [Drawing.Color]::FromArgb(17,16,20) }
    $fore = if ($selected) { [Drawing.Color]::White } else { $muted }
    $tabBrush = New-Object Drawing.SolidBrush($back)
    try { $eventArgs.Graphics.FillRectangle($tabBrush, $eventArgs.Bounds) } finally { $tabBrush.Dispose() }
    [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $sender.TabPages[$eventArgs.Index].Text,
        $sender.Font, $eventArgs.Bounds, $fore,
        [Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter)
})

$script:hoverTimers = New-Object Collections.ArrayList
function Add-SmoothButtonEffect($button, [Drawing.Color]$normal, [Drawing.Color]$hover) {
    $state = [pscustomobject]@{ R=[double]$normal.R; G=[double]$normal.G; B=[double]$normal.B; Target=$normal }
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 15
    $timer.Add_Tick({
        $state.R += ($state.Target.R - $state.R) * 0.30
        $state.G += ($state.Target.G - $state.G) * 0.30
        $state.B += ($state.Target.B - $state.B) * 0.30
        $button.BackColor = [Drawing.Color]::FromArgb([int][math]::Round($state.R),[int][math]::Round($state.G),[int][math]::Round($state.B))
        if ([math]::Abs($state.Target.R-$state.R) -lt 1 -and [math]::Abs($state.Target.G-$state.G) -lt 1 -and [math]::Abs($state.Target.B-$state.B) -lt 1) { $timer.Stop() }
    }.GetNewClosure())
    $button.Add_MouseEnter({ $state.Target = $hover; $timer.Start() }.GetNewClosure())
    $button.Add_MouseLeave({ $state.Target = $normal; $timer.Start() }.GetNewClosure())
    $button.Cursor = 'Hand'; $button.FlatAppearance.BorderSize = 0
    [void]$script:hoverTimers.Add($timer)
}

foreach ($primary in @($generate,$plusGenerate)) { Add-SmoothButtonEffect $primary $purple ([Drawing.Color]::FromArgb(185,130,219)) }
foreach ($secondary in @($copy,$clear,$plusCopy,$plusClear,$refreshButton,$copyIssuedButton)) { Add-SmoothButtonEffect $secondary $field ([Drawing.Color]::FromArgb(48,32,58)) }
Add-SmoothButtonEffect $deleteIssuedButton ([Drawing.Color]::FromArgb(75,20,35)) ([Drawing.Color]::FromArgb(115,32,50))
Add-SmoothButtonEffect $revokeIssuedButton ([Drawing.Color]::FromArgb(105,32,48)) ([Drawing.Color]::FromArgb(150,45,65))
Add-SmoothButtonEffect $ownerMinimize ([Drawing.Color]::FromArgb(24,19,29)) ([Drawing.Color]::FromArgb(50,32,61))
Add-SmoothButtonEffect $ownerMaximize ([Drawing.Color]::FromArgb(24,19,29)) ([Drawing.Color]::FromArgb(50,32,61))
Add-SmoothButtonEffect $ownerClose ([Drawing.Color]::FromArgb(24,19,29)) ([Drawing.Color]::FromArgb(115,32,50))

$licensesPage.Add_Resize({
    $usableWidth = [math]::Max(650, $licensesPage.ClientSize.Width - 36)
    $half = [math]::Floor(($usableWidth - 24) / 2)
    $standardList.Width = $half
    $splitLine.Left = 18 + $half + 11
    $plusHeading.Left = $splitLine.Left + 13
    $plusList.Left = $plusHeading.Left
    $plusList.Width = $half
    $standardList.Columns[0].Width = 72; $standardList.Columns[2].Width = 118; $standardList.Columns[1].Width = [math]::Max(75,$standardList.ClientSize.Width-194)
    $plusList.Columns[0].Width = 72; $plusList.Columns[2].Width = 118; $plusList.Columns[1].Width = [math]::Max(75,$plusList.ClientSize.Width-194)
    $listHeight = [math]::Max(210, $licensesPage.ClientSize.Height - 255)
    $standardList.Height = $listHeight; $plusList.Height = $listHeight; $splitLine.Height = $listHeight + 27
    $buttonTop = $standardList.Bottom + 16
    $copyIssuedButton.Top = $buttonTop; $deleteIssuedButton.Top = $buttonTop; $revokeIssuedButton.Top = $buttonTop; $licenseCount.Top = $buttonTop
})

$form.Opacity = 1
$form.Add_Shown({
    $form.WindowState = 'Normal'
    $form.ShowInTaskbar = $true
    $form.Activate()
    $form.BringToFront()
})

function Get-R6IssuedLicenses {
    if (-not (Test-Path -LiteralPath $ledgerPath)) { return @() }
    try {
        $normalizedRecords = @()
        foreach ($record in @(Import-Csv -LiteralPath $ledgerPath)) {
            $product = if ($record.PSObject.Properties.Name -contains 'Product' -and
                -not [string]::IsNullOrWhiteSpace($record.Product)) { $record.Product } else { 'R6 (:' }
            $normalizedRecords += [pscustomobject]@{
                IssuedUtc = $record.IssuedUtc
                Product = $product
                CustomerName = $record.CustomerName
                LicenseId = $record.LicenseId
                Serial = $record.Serial
            }
        }
        return @($normalizedRecords)
    }
    catch { throw 'The issuance ledger could not be read.' }
}

function Refresh-R6LicenseList {
    $selectedId = $null
    if ($standardList.SelectedItems.Count -gt 0) { $selectedId = $standardList.SelectedItems[0].SubItems[2].Text }
    if ($plusList.SelectedItems.Count -gt 0) { $selectedId = $plusList.SelectedItems[0].SubItems[2].Text }
    $standardList.BeginUpdate()
    $plusList.BeginUpdate()
    try {
        $standardList.Items.Clear()
        $plusList.Items.Clear()
        $query = $searchBox.Text.Trim()
        $standardShown = 0
        $plusShown = 0
        $standardTotal = 0
        $plusTotal = 0
        foreach ($record in @(Get-R6IssuedLicenses)) {
            if ($record.Product -eq 'R6 (:+') { $plusTotal++ } else { $standardTotal++ }
            $searchable = "$($record.Product) $($record.CustomerName) $($record.LicenseId) $($record.Serial) $($record.IssuedUtc)"
            if ($query.Length -gt 0 -and $searchable.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }
            $item = New-Object Windows.Forms.ListViewItem([string]$record.IssuedUtc)
            [void]$item.SubItems.Add([string]$record.CustomerName)
            [void]$item.SubItems.Add([string]$record.LicenseId)
            [void]$item.SubItems.Add([string]$record.Serial)
            $item.Tag = $record
            if ($record.Product -eq 'R6 (:+') {
                [void]$plusList.Items.Add($item)
                $plusShown++
            } else {
                [void]$standardList.Items.Add($item)
                $standardShown++
            }
            if ($null -ne $selectedId -and $record.LicenseId -eq $selectedId) { $item.Selected = $true }
        }
        $licenseCount.Text = if ($query.Length -gt 0) {
            "Standard $standardShown/$standardTotal  |  Plus $plusShown/$plusTotal"
        } else {
            "Standard $standardTotal  |  Plus $plusTotal"
        }
    } finally {
        $standardList.EndUpdate()
        $plusList.EndUpdate()
    }
}

function Get-R6SelectedLicenseItem {
    if ($standardList.SelectedItems.Count -gt 0) { return $standardList.SelectedItems[0] }
    if ($plusList.SelectedItems.Count -gt 0) { return $plusList.SelectedItems[0] }
    return $null
}

function Write-R6IssuedLicenses([object[]]$Records) {
    if ($Records.Count -gt 0) {
        $Records | Select-Object IssuedUtc,Product,CustomerName,LicenseId,Serial |
            Export-Csv -LiteralPath $ledgerPath -NoTypeInformation -Encoding UTF8
    } else {
        [IO.File]::WriteAllText($ledgerPath, "IssuedUtc,Product,CustomerName,LicenseId,Serial`r`n", [Text.UTF8Encoding]::new($false))
    }
}

function Add-R6DeletedLicenseId([string]$LicenseId) {
    $normalizedId = $LicenseId.Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedId)) { throw 'The selected record does not have a valid license ID.' }
    $ids = New-Object Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $deletedLicenseIdsPath) {
        foreach ($existingId in @(Get-Content -LiteralPath $deletedLicenseIdsPath -Encoding UTF8)) {
            $cleanExistingId = ([string]$existingId).Trim()
            if (-not [string]::IsNullOrWhiteSpace($cleanExistingId)) { [void]$ids.Add($cleanExistingId) }
        }
    }
    [void]$ids.Add($normalizedId)
    [IO.File]::WriteAllLines($deletedLicenseIdsPath, @($ids | Sort-Object), [Text.UTF8Encoding]::new($false))
    Write-R6RevocationManifest
}

function Add-R6IssuedLicense($License) {
    $records = @(Get-R6IssuedLicenses)
    $records += [pscustomobject]@{
        IssuedUtc = $License.IssuedUtc
        Product = $License.Product
        CustomerName = $License.Name
        LicenseId = $License.LicenseId
        Serial = $License.Serial
    }
    Write-R6IssuedLicenses $records
}

$generate.Add_Click({
    try {
        if (Test-R6NameAlreadyIssued $nameBox.Text 'R6 (:') {
            throw 'That customer name already has an R6 (: license. Use the existing ledger entry instead of generating another.'
        }
        $license = New-R6Serial $nameBox.Text 'R6 (:'
        $serialBox.Text = $license.Serial
        Add-R6IssuedLicense $license
        $status.Text = "Generated $($license.LicenseId) and recorded it in the stable owner ledger."
        $status.ForeColor = $muted
        Refresh-R6LicenseList
    } catch {
        $status.Text = $_.Exception.Message
        $status.ForeColor = [Drawing.Color]::FromArgb(238,92,120)
    }
})

$copy.Add_Click({
    if ($serialBox.Text.Length -gt 0) {
        [Windows.Forms.Clipboard]::SetText($serialBox.Text)
        $status.Text = 'Serial copied. Send the exact customer name and serial together.'
        $status.ForeColor = $muted
    }
})

$clear.Add_Click({
    $nameBox.Clear()
    $serialBox.Clear()
    $status.Text = 'Ready for a new customer.'
    $status.ForeColor = $muted
    $nameBox.Focus()
})

$plusGenerate.Add_Click({
    try {
        if (Test-R6NameAlreadyIssued $plusNameBox.Text 'R6 (:+') {
            throw 'That customer name already has an R6 (:+ license. Use the existing ledger entry instead of generating another.'
        }
        $license = New-R6Serial $plusNameBox.Text 'R6 (:+'
        $plusSerialBox.Text = $license.Serial
        Add-R6IssuedLicense $license
        $plusStatus.Text = "Generated Plus license $($license.LicenseId) and recorded it in the ledger."
        $plusStatus.ForeColor = $muted
        Refresh-R6LicenseList
    } catch {
        $plusStatus.Text = $_.Exception.Message
        $plusStatus.ForeColor = [Drawing.Color]::FromArgb(238,92,120)
    }
})

$plusCopy.Add_Click({
    if ($plusSerialBox.Text.Length -gt 0) {
        [Windows.Forms.Clipboard]::SetText($plusSerialBox.Text)
        $plusStatus.Text = 'Plus serial copied. Send it with the exact customer name.'
        $plusStatus.ForeColor = $muted
    }
})

$plusClear.Add_Click({
    $plusNameBox.Clear()
    $plusSerialBox.Clear()
    $plusStatus.Text = 'Ready for a new R6 (:+ customer.'
    $plusStatus.ForeColor = $muted
    $plusNameBox.Focus()
})

$searchBox.Add_TextChanged({
    try { Refresh-R6LicenseList }
    catch { $licenseCount.Text = $_.Exception.Message }
})

$refreshButton.Add_Click({
    try { Refresh-R6LicenseList }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'R6 (: License Records') | Out-Null }
})

$standardList.Add_SelectedIndexChanged({
    if ($standardList.SelectedItems.Count -gt 0) {
        foreach ($item in $plusList.Items) { $item.Selected = $false }
    }
})

$plusList.Add_SelectedIndexChanged({
    if ($plusList.SelectedItems.Count -gt 0) {
        foreach ($item in $standardList.Items) { $item.Selected = $false }
    }
})

$copyIssuedButton.Add_Click({
    $selected = Get-R6SelectedLicenseItem
    if ($null -eq $selected) {
        [Windows.Forms.MessageBox]::Show('Select an issued license first.', 'R6 (: License Records') | Out-Null
        return
    }
    $serial = $selected.SubItems[3].Text
    [Windows.Forms.Clipboard]::SetText($serial)
    $licenseCount.Text = 'Selected serial copied.'
})

$deleteIssuedButton.Add_Click({
    $selected = Get-R6SelectedLicenseItem
    if ($null -eq $selected) {
        [Windows.Forms.MessageBox]::Show('Select an issued license record first.', 'R6 (: License Records') | Out-Null
        return
    }
    $account = $selected.SubItems[1].Text
    $licenseId = $selected.SubItems[2].Text
    $warningText = "Permanently remove the owner record for '$account' ($licenseId)?`r`n`r`n" +
        'Older ledger copies will be prevented from restoring this license ID. The customer name may be issued again. ' +
        'The customer app will reject this license after it receives the updated revocation manifest.'
    if ([Windows.Forms.MessageBox]::Show($warningText, 'Confirm record deletion',
        [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning) -ne
        [Windows.Forms.DialogResult]::Yes) { return }
    try {
        Add-R6DeletedLicenseId $licenseId
        $remaining = @(Get-R6IssuedLicenses | Where-Object { $_.LicenseId -ne $licenseId })
        Write-R6IssuedLicenses $remaining
        Refresh-R6LicenseList
        $licenseCount.Text = "Revoked $account ($licenseId) and updated the revocation manifest."
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Delete failed') | Out-Null
    }
})

$revokeIssuedButton.Add_Click({
    $selected = Get-R6SelectedLicenseItem
    if ($null -eq $selected) {
        [Windows.Forms.MessageBox]::Show('Select an issued license first.', 'R6 (: License Records') | Out-Null
        return
    }
    $account = $selected.SubItems[1].Text
    $licenseId = $selected.SubItems[2].Text
    $warningText = "Deactivate '$account' ($licenseId)?`r`n`r`n" +
        'The owner revocation list will be updated and the customer app will reject this key. ' +
        'The ledger record will remain visible for auditing.'
    if ([Windows.Forms.MessageBox]::Show($warningText, 'Confirm key revocation',
        [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning) -ne
        [Windows.Forms.DialogResult]::Yes) { return }
    try {
        Add-R6DeletedLicenseId $licenseId
        Refresh-R6LicenseList
        $licenseCount.Text = "Deactivated $account ($licenseId)."
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Revocation failed') | Out-Null
    }
})

$licensesPage.Add_Enter({
    try { Refresh-R6LicenseList } catch { $licenseCount.Text = $_.Exception.Message }
})

Refresh-R6LicenseList

[void]$form.ShowDialog()

