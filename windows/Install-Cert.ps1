# C:\ProgramData\vault-agent\Install-Cert.ps1  -  ajetaan SYSTEMinä ajastetusti (Cert-Install).
# Asentaa keskuspalvelimen valmiiksi tekemän PFX:n tarkistusten jälkeen.
# Toimii Windows PowerShell 5.1:llä (.NET Framework 4.7.2+) ja PowerShell 7:llä.
#
# cert-install.json:
#   StagingDir      agentin staging-hakemisto
#   MinValidDays    hylkää varmenne, joka vanhenee tätä aiemmin
#   RevocationMode  Online | Offline | NoCheck   (puuttuu = Online, aiempi käytös)
#                   Ilmaraossa: NoCheck, tai Offline + DVV:n CRL koneen säilössä (docs/windows-liittaminen.md)
#   CrlStalePolicy  Warn | Fail   (Offline: vanhentunut/puuttuva CRL -> varoitus vai hylkäys; oletus Warn)
#   Certificates    { "nimi": [ "hostname:port", ... ] }
#
# Tarkistukset (CLAUDE.md, EI saa ohittaa): avain mukana, ketju päätyy NIMENOMAAN DVV:n juureen,
# voimassaolo >= MinValidDays, ei vanhempi kuin nykyinen. Avain tuodaan ei-vietävänä.
[CmdletBinding()]
param(
    [string]$Base = 'C:\ProgramData\vault-agent'
)
$ErrorActionPreference = 'Stop'
$IisAppId = '{4dc3e181-e14b-4a21-b022-59fc669b0914}'
$NS = 'System.Security.Cryptography.X509Certificates'

function Write-CertLog {
    param([ValidateSet('Information', 'Warning', 'Error')][string]$Type, [string]$Message)
    Write-EventLog -LogName Application -Source 'cert-install' -EventId 100 -EntryType $Type -Message $Message
}

# netsh-kääre (testattavuus)
function Invoke-Netsh { param([string[]]$Arguments) & netsh.exe @Arguments; $script:NetshExit = $LASTEXITCODE }

function Get-CertInstallConfig {
    param([string]$Path)
    $cfg = Get-Content $Path -Raw | ConvertFrom-Json
    $mode = if ($cfg.PSObject.Properties['RevocationMode'] -and $cfg.RevocationMode) { [string]$cfg.RevocationMode } else { 'Online' }
    if ($mode -notin 'Online', 'Offline', 'NoCheck') { throw "cert-install.json: RevocationMode '$mode' ei kelpaa (Online|Offline|NoCheck)" }
    $stale = if ($cfg.PSObject.Properties['CrlStalePolicy'] -and $cfg.CrlStalePolicy) { [string]$cfg.CrlStalePolicy } else { 'Warn' }
    if ($stale -notin 'Warn', 'Fail') { throw "cert-install.json: CrlStalePolicy '$stale' ei kelpaa (Warn|Fail)" }
    [pscustomobject]@{
        StagingDir     = [string]$cfg.StagingDir
        MinValidDays   = [int]$cfg.MinValidDays
        RevocationMode = $mode
        CrlStalePolicy = $stale
        Certificates   = $cfg.Certificates
    }
}

# Ketjun tarkistus: palauttaa @{ Ok; Warnings; Error }
function Test-CertChain {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Leaf,
        [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]$Extra,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$TrustedRoot,
        [string]$RevocationMode,
        [string]$CrlStalePolicy
    )
    $chain = New-Object "$NS.X509Chain"
    $chain.ChainPolicy.ExtraStore.AddRange($Extra)
    $chain.ChainPolicy.ExtraStore.Add($TrustedRoot) | Out-Null
    $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
    $chain.ChainPolicy.RevocationMode = $RevocationMode
    $chain.ChainPolicy.RevocationFlag = 'ExcludeRoot'
    $null = $chain.Build($Leaf)
    $top = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
    if ($top.Thumbprint -ne $TrustedRoot.Thumbprint) {
        return [pscustomobject]@{ Ok = $false; Warnings = @(); Error = 'ketju ei päädy DVV:n juureen' }
    }
    $revocationUnknown = 'RevocationStatusUnknown', 'OfflineRevocation'
    $warnings = @()
    $bad = @()
    foreach ($s in $chain.ChainStatus) {
        $st = [string]$s.Status
        if ($st -in 'UntrustedRoot', 'NoError') { continue }
        if ($st -in $revocationUnknown -and $RevocationMode -eq 'Offline' -and $CrlStalePolicy -eq 'Warn') {
            $warnings += "sulkutila tuntematon ($st): CRL puuttuu tai on vanhentunut"
            continue
        }
        $bad += $st
    }
    if ($bad) { return [pscustomobject]@{ Ok = $false; Warnings = $warnings; Error = 'ketjuvirhe: ' + (($bad | Select-Object -Unique) -join ', ') } }
    [pscustomobject]@{ Ok = $true; Warnings = $warnings; Error = $null }
}

# Poistettavat vanhat varmenteet: sama Subject JA sama myöntäjä (DVV:n välivarmenne), eri thumbprint.
# Ei koske muiden myöntäjien varmenteita, vaikka Subject olisi sama.
function Get-SupersededCert {
    param([object[]]$StoreCerts, [System.Security.Cryptography.X509Certificates.X509Certificate2]$New)
    @($StoreCerts | Where-Object {
            $_.Subject -eq $New.Subject -and $_.Issuer -eq $New.Issuer -and $_.Thumbprint -ne $New.Thumbprint
        })
}

# Nykyinen http.sys-sidoksen thumbprint (tai $null)
function Get-SslBindingThumbprint {
    param([string]$HostPort)
    $out = Invoke-Netsh -Arguments @('http', 'show', 'sslcert', "hostnameport=$HostPort")
    if ($script:NetshExit -ne 0) { return $null }
    $line = $out | Where-Object { $_ -match 'Certificate Hash\s*:\s*([0-9a-fA-F]{40})' } | Select-Object -First 1
    if ($line -and $line -match '([0-9a-fA-F]{40})') { return $Matches[1].ToUpperInvariant() }
    $null
}

# Luo tai päivittää SNI-sidoksen (http.sys). Palauttaa 'unchanged' | 'added' | 'updated'.
function Set-SslBinding {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([string]$HostPort, [string]$Thumbprint)
    $current = Get-SslBindingThumbprint -HostPort $HostPort
    if ($current -eq $Thumbprint.ToUpperInvariant()) { return 'unchanged' }
    $verb = if ($current) { 'update' } else { 'add' }
    if (-not $PSCmdlet.ShouldProcess($HostPort, "netsh http $verb sslcert")) { return 'whatif' }
    $null = Invoke-Netsh -Arguments @('http', $verb, 'sslcert', "hostnameport=$HostPort", "certhash=$Thumbprint", "appid=$IisAppId", 'certstorename=MY')
    if ($script:NetshExit -ne 0) { throw "sidoksen $verb epäonnistui: $HostPort" }
    if ($verb -eq 'add') { 'added' } else { 'updated' }
}

function Install-StagedCertificate {
    param($Cfg, [string]$Name, [string[]]$Bindings, $DvvRoot, $My, $Ca)
    $file = Join-Path $Cfg.StagingDir "$Name.pfx.txt"
    if (-not (Test-Path $file)) { return }
    $pw = $null; $bytes = $null
    try {
        $lines = [System.IO.File]::ReadAllLines($file)
        if ($lines.Count -lt 2) { throw 'tiedosto on vajaa' }
        $pw = $lines[0]
        $bytes = [Convert]::FromBase64String($lines[1])

        # Tarkistus avaimella, joka EI tallennu koneelle (EphemeralKeySet)
        $all = New-Object "$NS.X509Certificate2Collection"
        $all.Import($bytes, $pw, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        $leaf = $all | Where-Object HasPrivateKey | Select-Object -First 1
        if (-not $leaf) { throw 'PFX:ssä ei ole yksityistä avainta' }

        $installed = $My.Certificates.Find('FindByThumbprint', $leaf.Thumbprint, $false)
        if ($installed.Count -gt 0) {
            # Jo asennettu: varmista silti, että sidokset osoittavat siihen (korjaa puuttuvan/vanhan sidoksen).
            foreach ($hp in $Bindings) {
                $r = Set-SslBinding -HostPort $hp -Thumbprint $leaf.Thumbprint
                if ($r -ne 'unchanged') { Write-CertLog Warning "$Name sidos $hp korjattu ($r) -> $($leaf.Thumbprint)" }
            }
            return
        }

        # 1) Ketju DVV:n juureen (+ sulkulista valitulla tavalla)
        $chainResult = Test-CertChain -Leaf $leaf -Extra $all -TrustedRoot $DvvRoot -RevocationMode $Cfg.RevocationMode -CrlStalePolicy $Cfg.CrlStalePolicy
        if (-not $chainResult.Ok) { throw $chainResult.Error }
        foreach ($w in $chainResult.Warnings) { Write-CertLog Warning "${Name}: $w (CrlStalePolicy=Warn, jatketaan)" }

        # 2) Voimassaolo ja 3) ei vanhempi kuin nykyinen
        if ($leaf.NotAfter -lt (Get-Date).AddDays($Cfg.MinValidDays)) { throw "vanhenee pian ($($leaf.NotAfter))" }
        $current = $My.Certificates | Where-Object { $_.Subject -eq $leaf.Subject -and $_.Issuer -eq $leaf.Issuer } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($current -and $leaf.NotAfter -lt $current.NotAfter) { throw 'vanhempi kuin nykyinen varmenne' }

        # Tuonti: avain koneen avainsäilöön, EI vietävissä (ei Exportable-lippua)
        $cert = New-Object "$NS.X509Certificate2" -ArgumentList $bytes, $pw,
            ([System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]'MachineKeySet,PersistKeySet')
        $My.Add($cert)
        # Välivarmenteet Intermediate-säilöön, jotta IIS lähettää koko ketjun
        $all | Where-Object { -not $_.HasPrivateKey -and $_.Subject -ne $_.Issuer } | ForEach-Object { $Ca.Add($_) }

        foreach ($hp in $Bindings) { $null = Set-SslBinding -HostPort $hp -Thumbprint $cert.Thumbprint }
        Get-SupersededCert -StoreCerts @($My.Certificates) -New $cert | ForEach-Object { $My.Remove($_) }

        Write-CertLog Information "$Name asennettu: $($cert.Thumbprint), voimassa $($cert.NotAfter) asti, sidokset: $($Bindings -join ', ')"
    }
    catch {
        Write-CertLog Error "$Name hylätty, vanha varmenne jää voimaan: $($_.Exception.Message)"
    }
    finally {
        $pw = $null; $bytes = $null
    }
}

function Invoke-CertInstall {
    param([string]$Base)
    $cfg = Get-CertInstallConfig -Path (Join-Path $Base 'cert-install.json')
    $dvvRoot = New-Object "$NS.X509Certificate2" (Join-Path $Base 'dvv-ca.pem')
    $my = New-Object "$NS.X509Store" 'My', 'LocalMachine'; $my.Open('ReadWrite')
    $ca = New-Object "$NS.X509Store" 'CA', 'LocalMachine'; $ca.Open('ReadWrite')
    try {
        foreach ($entry in $cfg.Certificates.PSObject.Properties) {
            Install-StagedCertificate -Cfg $cfg -Name $entry.Name -Bindings @($entry.Value) -DvvRoot $dvvRoot -My $my -Ca $ca
        }
    }
    finally { $my.Close(); $ca.Close() }
}

# Suoritetaan vain ajettaessa skriptinä (ei dot-sourcattaessa testeissä)
if ($MyInvocation.InvocationName -ne '.') { Invoke-CertInstall -Base $Base }
