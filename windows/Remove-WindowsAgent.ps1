<#
.SYNOPSIS
    Poistaa palvelimen DVV ACME -varmennejakelusta.

.DESCRIPTION
    Pysäyttää ja poistaa vault-agent-palvelun ja Cert-Install-tehtävän, hävittää tunnisteet
    (secret_id ylikirjoitetaan ennen poistoa) ja staging-tiedostot. Tulostaa lopuksi Vault-puolen
    komennot (secret_id:n hävitys, roolin ja policyn poisto), jotka ylläpitäjä ajaa keskuksessa.
    Varmenteita ja IIS-sidoksia EI poisteta oletuksena (palvelu jatkaa nykyisellä varmenteella).

.PARAMETER RemoveCertificates
    Poista myös cert-install.json:n varmenteiden http.sys-sidokset ja asennetut DVV-varmenteet.

.PARAMETER RemoveFiles
    Poista koko C:\ProgramData\vault-agent ja vault.exe.

.EXAMPLE
    .\Remove-WindowsAgent.ps1 -Server web01 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Palvelimen nimi Vaultissa (onboard-server.sh); oletus: koneen nimi pienillä kirjaimilla
    [string]$Server = $env:COMPUTERNAME.ToLowerInvariant(),
    [string]$InstallDir = 'C:\ProgramData\vault-agent',
    [string]$VaultInstallDir = 'C:\Program Files\Vault',
    [switch]$RemoveCertificates,
    [switch]$RemoveFiles
)
$ErrorActionPreference = 'Stop'
$ServiceName = 'vault-agent'

function Write-Step { param([string]$Message) Write-Information "[poisto] $Message" -InformationAction Continue }

# Ylikirjoittaa tiedoston satunnaisdatalla ennen poistoa (NTFS: ei takuuta SSD:llä, mutta
# estää tavallisen palautuksen; varsinainen suoja on secret_id:n hävitys Vaultissa).
function Remove-SensitiveFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($PSCmdlet.ShouldProcess($Path, 'Ylikirjoita ja poista')) {
        $len = (Get-Item -LiteralPath $Path).Length
        $buf = New-Object byte[] ([Math]::Max($len, 64))
        (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($buf)
        [System.IO.File]::WriteAllBytes($Path, $buf)
        Remove-Item -LiteralPath $Path -Force
        Write-Step "poistettu: $Path"
    }
}

function Remove-AgentService {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $PSCmdlet.ShouldProcess($ServiceName, 'Pysäytä ja poista palvelu')) {
        if ($svc.Status -ne 'Stopped') { Stop-Service $ServiceName -Force }
        sc.exe delete $ServiceName | Out-Null
        Write-Step 'palvelu vault-agent poistettu'
    }
    if ((Get-ScheduledTask -TaskName 'Cert-Install' -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess('Cert-Install', 'Poista ajastettu tehtävä')) {
        Unregister-ScheduledTask -TaskName 'Cert-Install' -Confirm:$false
        Write-Step 'tehtävä Cert-Install poistettu'
    }
}

function Remove-ManagedCertificate {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ConfigPath, [string]$InstallDir)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Step 'cert-install.json puuttuu: varmenteita ei poisteta'; return }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $dvv = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (Join-Path $InstallDir 'dvv-ca.pem')
    $my = New-Object System.Security.Cryptography.X509Certificates.X509Store 'My', 'LocalMachine'
    $my.Open('ReadWrite')
    try {
        foreach ($entry in $cfg.Certificates.PSObject.Properties) {
            foreach ($hp in @($entry.Value)) {
                $out = & netsh.exe http show sslcert "hostnameport=$hp" 2>$null
                $hash = ($out | Where-Object { $_ -match 'Certificate Hash\s*:\s*([0-9a-fA-F]{40})' } | Select-Object -First 1)
                if ($hash -and $hash -match '([0-9a-fA-F]{40})') {
                    $tp = $Matches[1]
                    if ($PSCmdlet.ShouldProcess($hp, 'Poista http.sys-sidos')) {
                        & netsh.exe http delete sslcert "hostnameport=$hp" | Out-Null
                        Write-Step "sidos poistettu: $hp"
                    }
                    # Poistetaan vain varmenne, jonka ketju on DVV:n (myöntäjä ei ole itse allekirjoitettu muu)
                    $c = $my.Certificates.Find('FindByThumbprint', $tp, $false) | Select-Object -First 1
                    if ($c) {
                        $ch = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                        $ch.ChainPolicy.ExtraStore.Add($dvv) | Out-Null
                        $ch.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
                        $ch.ChainPolicy.RevocationMode = 'NoCheck'
                        $null = $ch.Build($c)
                        $root = $ch.ChainElements[$ch.ChainElements.Count - 1].Certificate
                        if ($root.Thumbprint -eq $dvv.Thumbprint -and $PSCmdlet.ShouldProcess($c.Subject, 'Poista varmenne')) {
                            $my.Remove($c); Write-Step "varmenne poistettu: $($c.Subject) $tp"
                        }
                    }
                }
            }
        }
    }
    finally { $my.Close() }
}

function Invoke-RemoveWindowsAgent {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Server, [string]$InstallDir, [string]$VaultInstallDir, [switch]$RemoveCertificates, [switch]$RemoveFiles)
    if ($Server -notmatch '^[a-z0-9-]+$') { throw "Palvelimen nimi '$Server' ei kelpaa (a-z 0-9 -); anna -Server" }
    Remove-AgentService
    if ($RemoveCertificates) { Remove-ManagedCertificate -ConfigPath (Join-Path $InstallDir 'cert-install.json') -InstallDir $InstallDir }
    foreach ($f in 'secret_id', 'role_id') { Remove-SensitiveFile -Path (Join-Path $InstallDir $f) }
    Get-ChildItem -LiteralPath (Join-Path $InstallDir 'staging') -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-SensitiveFile -Path $_.FullName }
    if ($RemoveFiles -and $PSCmdlet.ShouldProcess($InstallDir, 'Poista hakemisto ja vault.exe')) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $VaultInstallDir 'vault.exe') -Force -ErrorAction SilentlyContinue
        Write-Step "poistettu: $InstallDir ja vault.exe"
    }
    Write-Output @"

Palvelin $Server on poistettu paikallisesti. Viimeistele keskuksessa (ylläpitäjä, acmesvc):

  onboard-server.sh remove $Server

  (hävittää kaikki roolin secret_id:t, poistaa AppRole-roolin auth/approle/role/$Server
   ja policyn cert-$Server). Ennen sitä palvelimen mahdollisesti vuotanut secret_id toimii
   edelleen roolin IP-sidonnan rajoissa.
"@
    if (-not $RemoveCertificates) { Write-Output 'Varmenteet ja IIS-sidokset jätettiin paikalleen (-RemoveCertificates poistaa ne).' }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-RemoveWindowsAgent -Server $Server -InstallDir $InstallDir -VaultInstallDir $VaultInstallDir `
        -RemoveCertificates:$RemoveCertificates -RemoveFiles:$RemoveFiles
}
