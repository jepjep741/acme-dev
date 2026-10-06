<#
.SYNOPSIS
    Liittää Windows/IIS-palvelimen DVV ACME -varmennejakeluun yhdellä komennolla.

.DESCRIPTION
    1. Esitarkistukset ENNEN muutoksia: ylläpitäjä, käyttöjärjestelmä, .NET >= 4.7.2, IIS,
       tiedostot ja vault.exe:n SHA256, Vault TCP + TLS (ca.pem), Vaultin tila, kellon poikkeama
       Vaultiin, skriptien allekirjoitus. Jos jokin puuttuu, keskeytetään ja kerrotaan korjaus.
    2. vault.exe paikallisesta jakelusta (ei internetistä), SHA256 tarkistettu.
    3. Wrapping token puretaan paikallisesti -> secret_id suoraan tiedostoon (ACL: SYSTEM,
       Administrators, NT SERVICE\vault-agent). Käytetty/vanhentunut kääre = mahdollinen vuoto.
    4. agent.hcl ja cert-install.json parametreista, IIS HTTPS -sidokset (SNI), Setup-VaultAgent.ps1.
    5. Odottaa, että Install-Cert.ps1 on asentanut jokaisen varmenteen, ja todentaa TLS-yhteydellä,
       että IIS tarjoilee sitä (thumbprint ja voimassaolo).
    Idempotentti: uudelleenajo päivittää konfiguraation; ilman -WrappingTokenia secret_id säilyy.

.PARAMETER ParameterFile
    JSON-parametritiedosto (onboard-server.sh csv). Komentorivin parametrit ohittavat tiedoston arvot.
    Tiedostossa EI ole salaisuuksia; wrapping token annetaan aina erikseen.

.EXAMPLE
    .\Install-WindowsAgent.ps1 -ParameterFile .\web01.json -WrappingToken (Read-Host -AsSecureString 'Kääre')

.EXAMPLE
    .\Install-WindowsAgent.ps1 -VaultAddress https://vault.asiakas.fi:8200 -RoleId <uuid> `
        -Certificates @{ intranet = @('intranet.asiakas.fi:443') } -CaPath .\ca.pem -DvvCaPath .\dvv-ca.pem `
        -VaultExeSource \\jako\vault\vault.exe -VaultExeSha256 <sha256> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ParameterFile,
    [string]$VaultAddress,
    [string]$RoleId,
    [securestring]$WrappingToken,
    [hashtable]$Certificates,
    [string]$CaPath,
    [string]$DvvCaPath,
    [string]$VaultExeSource,
    [string]$VaultExeSha256,
    [string]$IisSite,
    [ValidateSet('Online', 'Offline', 'NoCheck')][string]$RevocationMode,
    [ValidateSet('Warn', 'Fail')][string]$CrlStalePolicy,
    [int]$MinValidDays,
    [int]$TimeoutSeconds = 600,
    [int]$MaxClockSkewSeconds = 60,
    [string]$InstallDir = 'C:\ProgramData\vault-agent',
    [string]$VaultInstallDir = 'C:\Program Files\Vault',
    # Vain testiympäristöön: ohita Install-Cert.ps1:n allekirjoitustarkistus
    [switch]$SkipSignatureCheck,
    # Älä odota asennusta äläkä todenna IIS:ää (esim. massajakelussa erillinen tarkistus)
    [switch]$SkipVerify
)
$ErrorActionPreference = 'Stop'
$ServiceName = 'vault-agent'
$ServiceSid = "NT SERVICE\$ServiceName"
$NS = 'System.Security.Cryptography.X509Certificates'

function Write-Step { param([string]$Message) Write-Information "[liittäminen] $Message" -InformationAction Continue }

# ----------------------------------------------------------------- parametrit
function Get-ParameterFileValue {
    param([object]$Json, [string]$Name)
    if ($null -ne $Json -and $Json.PSObject.Properties[$Name]) { return $Json.$Name }
    $null
}

# Yhdistää parametritiedoston ja komentorivin (komentorivi voittaa) ja tarkistaa arvot.
function Resolve-InstallSetting {
    param([hashtable]$Bound, [string]$ParameterFile)
    $json = $null
    if ($ParameterFile) {
        if (-not (Test-Path -LiteralPath $ParameterFile)) { throw "Parametritiedostoa ei löydy: $ParameterFile" }
        $json = Get-Content -LiteralPath $ParameterFile -Raw | ConvertFrom-Json
        foreach ($forbidden in 'WrappingToken', 'SecretId', 'secret_id', 'wrapping_token') {
            if ($json.PSObject.Properties[$forbidden]) { throw "Parametritiedostossa ei saa olla salaisuuksia ($forbidden). Anna wrapping token erikseen." }
        }
    }
    $defaults = @{ IisSite = 'Default Web Site'; RevocationMode = 'NoCheck'; CrlStalePolicy = 'Warn'; MinValidDays = 7 }
    $s = @{}
    foreach ($k in 'VaultAddress', 'RoleId', 'CaPath', 'DvvCaPath', 'VaultExeSource', 'VaultExeSha256', 'IisSite', 'RevocationMode', 'CrlStalePolicy', 'MinValidDays') {
        if ($Bound.ContainsKey($k) -and $null -ne $Bound[$k] -and "$($Bound[$k])" -ne '') { $s[$k] = $Bound[$k] }
        elseif ($null -ne (Get-ParameterFileValue $json $k)) { $s[$k] = Get-ParameterFileValue $json $k }
        elseif ($defaults.ContainsKey($k)) { $s[$k] = $defaults[$k] }
        else { $s[$k] = $null }
    }
    # Suhteelliset polut parametritiedoston hakemistoon nähden
    if ($ParameterFile) {
        $dir = Split-Path -Parent (Resolve-Path -LiteralPath $ParameterFile)
        foreach ($k in 'CaPath', 'DvvCaPath', 'VaultExeSource') {
            if ($s[$k] -and -not [System.IO.Path]::IsPathRooted([string]$s[$k]) -and -not $Bound.ContainsKey($k)) {
                $s[$k] = Join-Path $dir $s[$k]
            }
        }
    }
    $certs = [ordered]@{}
    if ($Bound.ContainsKey('Certificates') -and $Bound['Certificates']) {
        foreach ($k in ($Bound['Certificates'].Keys | Sort-Object)) { $certs[$k] = @($Bound['Certificates'][$k]) }
    }
    elseif ($null -ne (Get-ParameterFileValue $json 'Certificates')) {
        foreach ($p in $json.Certificates.PSObject.Properties) { $certs[$p.Name] = @($p.Value) }
    }
    $s['Certificates'] = $certs
    $s['MinValidDays'] = [int]$s['MinValidDays']
    $s['Server'] = Get-ParameterFileValue $json 'Server'

    $errors = @(Test-InstallSetting -Setting $s)
    if ($errors) { throw ("Virheelliset parametrit:`n  - " + ($errors -join "`n  - ")) }
    [pscustomobject]$s
}

function Test-InstallSetting {
    param([hashtable]$Setting)
    $e = @()
    if ($Setting.VaultAddress -notmatch '^https://[A-Za-z0-9.-]+(:\d{1,5})?/?$') { $e += "VaultAddress puuttuu tai ei ole muotoa https://nimi:portti ($($Setting.VaultAddress))" }
    if ($Setting.RoleId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { $e += 'RoleId puuttuu tai ei ole UUID (onboard-server.sh tulostaa sen)' }
    foreach ($k in 'CaPath', 'DvvCaPath', 'VaultExeSource') { if (-not $Setting[$k]) { $e += "$k puuttuu" } }
    if ($Setting.VaultExeSha256 -notmatch '^[0-9a-fA-F]{64}$') { $e += 'VaultExeSha256 puuttuu tai ei ole SHA256 (julkaisupaketin SHA256SUMS)' }
    if ($Setting.RevocationMode -notin 'Online', 'Offline', 'NoCheck') { $e += "RevocationMode '$($Setting.RevocationMode)' ei kelpaa" }
    if ($Setting.CrlStalePolicy -notin 'Warn', 'Fail') { $e += "CrlStalePolicy '$($Setting.CrlStalePolicy)' ei kelpaa" }
    if ($Setting.MinValidDays -lt 1) { $e += 'MinValidDays on oltava >= 1' }
    if (-not $Setting.Certificates -or $Setting.Certificates.Count -eq 0) { $e += 'Certificates puuttuu (nimi -> hostname:port)' }
    foreach ($name in $Setting.Certificates.Keys) {
        if ($name -notmatch '^[a-z0-9-]+$') { $e += "varmenteen nimi '$name' ei kelpaa (a-z 0-9 -)" }
        if (@($Setting.Certificates[$name]).Count -eq 0) { $e += "varmenteella '$name' ei ole sidoksia" }
        foreach ($b in @($Setting.Certificates[$name])) {
            if ($b -notmatch '^[A-Za-z0-9.-]+:\d{1,5}$') { $e += "sidos '$b' ei ole muotoa hostname:port" }
        }
    }
    $e
}

# ----------------------------------------------------------------- konfiguraatiot
function ConvertTo-HclPath { param([string]$Path) $Path -replace '\\', '/' }

function Get-AgentHclContent {
    param([pscustomobject]$Setting, [string]$InstallDir)
    $d = ConvertTo-HclPath $InstallDir
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Luotu: Install-WindowsAgent.ps1. Älä muokkaa käsin; aja skripti uudelleen.')
    [void]$sb.AppendLine('# Agentti ajetaan virtuaalitilillä NT SERVICE\vault-agent ja kirjoittaa vain staging-hakemistoon.')
    [void]$sb.AppendLine("pid_file = `"$d/run/pid`"")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('vault {')
    [void]$sb.AppendLine("  address = `"$($Setting.VaultAddress.TrimEnd('/'))`"")
    [void]$sb.AppendLine("  ca_cert = `"$d/ca.pem`"")
    [void]$sb.AppendLine('  retry { num_retries = 5 }')
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('auto_auth {')
    [void]$sb.AppendLine('  method "approle" {')
    [void]$sb.AppendLine('    config = {')
    [void]$sb.AppendLine("      role_id_file_path                   = `"$d/role_id`"")
    [void]$sb.AppendLine("      secret_id_file_path                 = `"$d/secret_id`"")
    [void]$sb.AppendLine('      remove_secret_id_file_after_reading = false')
    [void]$sb.AppendLine('    }')
    [void]$sb.AppendLine('  }')
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('template_config {')
    [void]$sb.AppendLine('  static_secret_render_interval = "1h"')
    [void]$sb.AppendLine('  exit_on_retry_failure         = false')
    [void]$sb.AppendLine('}')
    foreach ($name in $Setting.Certificates.Keys) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("# $name : rivi 1 = PFX:n salasana, rivi 2 = PFX base64 (atominen kirjoitus)")
        [void]$sb.AppendLine('template {')
        [void]$sb.AppendLine("  contents             = `"{{ with secret \`"secret/data/certs/$name\`" }}{{ .Data.data.pfx_password }}\n{{ .Data.data.pfx_b64 }}{{ end }}`"")
        [void]$sb.AppendLine("  destination          = `"$d/staging/$name.pfx.txt`"")
        [void]$sb.AppendLine('  error_on_missing_key = true')
        [void]$sb.AppendLine('}')
    }
    $sb.ToString()
}

function Get-CertInstallJsonContent {
    param([pscustomobject]$Setting, [string]$InstallDir)
    $certs = [ordered]@{}
    foreach ($name in $Setting.Certificates.Keys) { $certs[$name] = @($Setting.Certificates[$name]) }
    [ordered]@{
        StagingDir     = (Join-Path $InstallDir 'staging')
        MinValidDays   = $Setting.MinValidDays
        RevocationMode = $Setting.RevocationMode
        CrlStalePolicy = $Setting.CrlStalePolicy
        Certificates   = $certs
    } | ConvertTo-Json -Depth 5
}

# Kirjoittaa tiedoston vain jos sisältö muuttuu. Palauttaa $true jos kirjoitettiin.
function Set-FileContentIfChanged {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$Path, [string]$Content)
    if ((Test-Path -LiteralPath $Path) -and ([System.IO.File]::ReadAllText($Path) -ceq $Content)) { return $false }
    if ($PSCmdlet.ShouldProcess($Path, 'Kirjoita')) { [System.IO.File]::WriteAllText($Path, $Content) }
    $true
}

# ----------------------------------------------------------------- tarkistukset
function Get-CheckResult { param([string]$Name, [bool]$Ok, [string]$Message, [string]$Fix) [pscustomobject]@{ Tarkistus = $Name; Ok = $Ok; Tulos = $Message; Korjaus = $Fix } }

function Test-IsAdministrator {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object System.Security.Principal.WindowsPrincipal $id).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OsInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    [pscustomobject]@{ Caption = $os.Caption; Build = [int]$os.BuildNumber; ProductType = [int]$os.ProductType }
}

function Get-DotNetRelease {
    $k = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction SilentlyContinue
    if ($k) { [int]$k.Release } else { 0 }
}

function Test-IisInstalled {
    $svc = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
    $mod = Get-Module -ListAvailable -Name WebAdministration
    [bool]($svc -and $mod)
}

function Get-FileSha256 { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Test-TcpPort {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 5000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($iar); $true
    }
    catch { $false }
    finally { $c.Close() }
}

# TLS-yhteys, joka luottaa VAIN annettuun CA:han (ei järjestelmän säilöön). Valinnainen HTTP GET.
# Palauttaa: Ok, Error, Certificate, StatusCode, Date
function Invoke-TlsProbe {
    param([string]$ComputerName, [int]$Port, [string]$ServerName, [string]$CaPath, [string]$HttpPath)
    $result = [pscustomobject]@{ Ok = $false; Error = $null; Certificate = $null; StatusCode = 0; Date = $null }
    $trusted = New-Object "$NS.X509Certificate2Collection"
    $trusted.Import($CaPath)
    $script:TlsProbeError = $null
    $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
        param($src, $cert, $chainIn, $errors)
        $null = $src, $chainIn
        if ($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) { $script:TlsProbeError = 'nimi ei täsmää varmenteeseen'; return $false }
        if ($null -eq $cert) { $script:TlsProbeError = 'ei varmennetta'; return $false }
        $c2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cert
        $ch = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $ch.ChainPolicy.ExtraStore.AddRange($trusted)
        $ch.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
        $ch.ChainPolicy.RevocationMode = 'NoCheck'
        $null = $ch.Build($c2)
        $root = $ch.ChainElements[$ch.ChainElements.Count - 1].Certificate
        $isTrusted = @($trusted | Where-Object { $_.Thumbprint -eq $root.Thumbprint }).Count -gt 0
        $bad = $ch.ChainStatus | Where-Object { [string]$_.Status -notin 'UntrustedRoot', 'NoError' }
        if (-not $isTrusted) { $script:TlsProbeError = 'varmenne ei ole annetun CA:n myöntämä'; return $false }
        if ($bad) { $script:TlsProbeError = 'ketjuvirhe: ' + (($bad | ForEach-Object Status) -join ', '); return $false }
        $true
    }
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp.Connect($ComputerName, $Port)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $callback)
        $ssl.AuthenticateAsClient($ServerName)
        $result.Certificate = New-Object "$NS.X509Certificate2" $ssl.RemoteCertificate
        if ($HttpPath) {
            $req = [System.Text.Encoding]::ASCII.GetBytes("GET $HttpPath HTTP/1.1`r`nHost: ${ServerName}:$Port`r`nConnection: close`r`n`r`n")
            $ssl.Write($req, 0, $req.Length); $ssl.Flush()
            $reader = New-Object System.IO.StreamReader($ssl)
            $status = $reader.ReadLine()
            if ($status -match '^HTTP/\d\.\d (\d{3})') { $result.StatusCode = [int]$Matches[1] }
            while (($line = $reader.ReadLine())) {
                if ($line -match '^Date:\s*(.+)$') { $result.Date = [datetime]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() }
            }
        }
        $result.Ok = $true
    }
    catch {
        $result.Error = if ($script:TlsProbeError) { $script:TlsProbeError } else { $_.Exception.GetBaseException().Message }
    }
    finally { $tcp.Close() }
    $result
}

function Test-ScriptSigned { param([string]$Path) (Get-AuthenticodeSignature -FilePath $Path).Status -eq 'Valid' }

# Kaikki esitarkistukset. Ei muutoksia. Palauttaa tulosrivit.
function Invoke-Precheck {
    param([pscustomobject]$Setting, [bool]$NeedWrappingToken, [string]$InstallCertSource, [int]$MaxClockSkewSeconds, [switch]$SkipSignatureCheck)
    $r = @()
    $r += Get-CheckResult -Name 'Ylläpitäjäoikeudet' -Ok (Test-IsAdministrator) -Message 'PowerShell ylläpitäjänä' -Fix 'Käynnistä PowerShell "Suorita järjestelmänvalvojana"'

    $os = Get-OsInfo
    $osOk = $os.Build -ge 14393 -and $os.ProductType -ne 1
    $osMsg = "$($os.Caption) (build $($os.Build))"
    if ($os.Build -lt 17763 -and $osOk) { $osMsg += ': Server 2016 -> keskuksessa PFX_COMPAT=legacy' }
    $r += Get-CheckResult -Name 'Käyttöjärjestelmä' -Ok $osOk -Message $osMsg -Fix 'Tuetut: Windows Server 2016/2019/2022'

    $rel = Get-DotNetRelease
    $r += Get-CheckResult -Name '.NET Framework >= 4.7.2' -Ok ($rel -ge 461808) -Message "Release $rel" -Fix 'Asenna .NET Framework 4.7.2 tai uudempi (EphemeralKeySet)'

    $r += Get-CheckResult -Name 'IIS' -Ok (Test-IisInstalled) -Message 'W3SVC + WebAdministration' -Fix 'Install-WindowsFeature Web-Server,Web-Scripting-Tools'

    foreach ($k in 'CaPath', 'DvvCaPath', 'VaultExeSource') {
        $p = [string]$Setting.$k
        $r += Get-CheckResult -Name "Tiedosto $k" -Ok ([bool]($p -and (Test-Path -LiteralPath $p))) -Message $p -Fix 'Kopioi julkaisupaketista (bin/, ca.pem, dvv-ca.pem)'
    }
    if ($Setting.VaultExeSource -and (Test-Path -LiteralPath $Setting.VaultExeSource)) {
        $h = Get-FileSha256 $Setting.VaultExeSource
        $r += Get-CheckResult -Name 'vault.exe SHA256' -Ok ($h -eq $Setting.VaultExeSha256.ToLowerInvariant()) -Message $h -Fix 'Väärä tai muuttunut vault.exe: hae julkaisupaketista ja tarkista SHA256SUMS'
    }

    $u = [uri]$Setting.VaultAddress
    $port = if ($u.IsDefaultPort) { 443 } else { $u.Port }
    $tcpOk = Test-TcpPort -ComputerName $u.Host -Port $port
    $r += Get-CheckResult -Name 'Yhteys Vaultiin (TCP)' -Ok $tcpOk -Message "$($u.Host):$port" -Fix 'Avaa palomuuri palvelin -> Vault TCP 8200; tarkista DNS-nimi'
    if ($tcpOk -and (Test-Path -LiteralPath $Setting.CaPath)) {
        $probe = Invoke-TlsProbe -ComputerName $u.Host -Port $port -ServerName $u.Host -CaPath $Setting.CaPath -HttpPath '/v1/sys/health'
        $r += Get-CheckResult -Name 'Vaultin TLS (ca.pem)' -Ok $probe.Ok -Message ([string]$(if ($probe.Ok) { 'OK' } else { $probe.Error })) -Fix 'Tarkista ca.pem (keskuksen tls/ca.pem) ja että nimi on varmenteen SAN:ssa'
        if ($probe.Ok) {
            $sealedMsg = switch ($probe.StatusCode) { 200 { 'avattu' } 429 { 'standby' } 503 { 'SINETÖITY' } 501 { 'alustamaton' } default { "HTTP $($probe.StatusCode)" } }
            $r += Get-CheckResult -Name 'Vaultin tila' -Ok ($probe.StatusCode -in 200, 429) -Message $sealedMsg -Fix 'Pyydä keskuksen ylläpitoa avaamaan Vault (vault-unseal.sh)'
            if ($probe.Date) {
                $skew = [math]::Abs(((Get-Date).ToUniversalTime() - $probe.Date).TotalSeconds)
                $r += Get-CheckResult -Name 'Kellon poikkeama Vaultiin' -Ok ($skew -le $MaxClockSkewSeconds) -Message ("{0:N0} s" -f $skew) -Fix 'Korjaa aika sisäisestä NTP:stä: w32tm /resync'
            }
        }
    }

    if (-not $SkipSignatureCheck) {
        $signed = Test-ScriptSigned $InstallCertSource
        $r += Get-CheckResult -Name 'Install-Cert.ps1 allekirjoitettu' -Ok $signed -Message $InstallCertSource -Fix 'Allekirjoita: Set-AuthenticodeSignature (koodinallekirjoitusvarmenne); tehtävä käyttää AllSigned'
    }
    if ($NeedWrappingToken) {
        $r += Get-CheckResult -Name 'Wrapping token' -Ok $false -Message 'puuttuu (ei aiempaa secret_id:tä)' -Fix 'Anna -WrappingToken (onboard-server.sh wrap <palvelin>)'
    }
    $r
}

# ----------------------------------------------------------------- muutokset
function ConvertFrom-SecureStringPlain {
    param([securestring]$Value)
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# vault.exe:n ajo: salaisuudet vain lapsiprosessin ympäristöön (ei komentoriville). Palauttaa ExitCode, StdOut, StdErr.
function Invoke-VaultCli {
    param([string]$VaultExe, [string[]]$Arguments, [hashtable]$Environment)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $VaultExe
    $psi.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err }
}

# Puretaan kääre. Epäonnistuminen = käytetty/vanhentunut/siepattu kääre -> keskeytetään.
function Get-UnwrappedSecretId {
    param([string]$VaultExe, [string]$VaultAddress, [string]$CaPath, [securestring]$WrappingToken)
    $tok = ConvertFrom-SecureStringPlain $WrappingToken
    try {
        $r = Invoke-VaultCli -VaultExe $VaultExe -Arguments @('unwrap', '-field=secret_id') -Environment @{
            VAULT_ADDR = $VaultAddress; VAULT_CACERT = $CaPath; VAULT_TOKEN = $tok
        }
    }
    finally { $tok = $null }
    if ($r.ExitCode -ne 0 -or -not $r.StdOut.Trim()) {
        $hint = ''
        if ($r.StdErr -match 'wrapping token is not valid|does not exist|token not found|permission denied') {
            $hint = ' Kääre on jo käytetty tai vanhentunut (15 min). Jos et itse purkanut sitä, joku on voinut siepata sen:' +
                ' ÄLÄ ota käyttöön, ilmoita ylläpidolle (secret_id hävitetään) ja pyydä uusi: onboard-server.sh wrap <palvelin>.'
        }
        throw "Wrapping tokenin purku epäonnistui.$hint"
    }
    $r.StdOut.Trim()
}

# Tiedosto, jonka ACL on vain SYSTEM, Administrators ja (luku) annettu tili. Sisältö kirjoitetaan
# vasta, kun ACL on asetettu.
function Set-ProtectedFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [string]$Content, [string]$ReaderAccount)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Kirjoita suojattu tiedosto')) { return }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @(@('SYSTEM', 'FullControl'), @('BUILTIN\Administrators', 'FullControl'), @($ReaderAccount, 'Read'))) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($rule[0], $rule[1], 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    [System.IO.File]::WriteAllText($Path, $Content)
}

function Install-VaultExecutable {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Source, [string]$Sha256, [string]$TargetDir)
    $target = Join-Path $TargetDir 'vault.exe'
    if ((Test-Path -LiteralPath $target) -and (Get-FileSha256 $target) -eq $Sha256.ToLowerInvariant()) {
        Write-Step "vault.exe ajan tasalla ($target)"; return $target
    }
    if ($PSCmdlet.ShouldProcess($target, 'Kopioi vault.exe')) {
        New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
        $running = Get-Service $ServiceName -ErrorAction SilentlyContinue
        if ($running -and $running.Status -eq 'Running') { Stop-Service $ServiceName }
        Copy-Item -LiteralPath $Source -Destination $target -Force
        if ((Get-FileSha256 $target) -ne $Sha256.ToLowerInvariant()) { Remove-Item $target -Force; throw 'vault.exe:n SHA256 ei täsmää kopioinnin jälkeen' }
        Write-Step "vault.exe asennettu ($target)"
    }
    $target
}

function Get-IisHttpsBinding { param([string]$Site, [string]$HostHeader, [int]$Port) Get-WebBinding -Name $Site -Protocol https -Port $Port -HostHeader $HostHeader }

function Add-IisHttpsBinding {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Site, [string[]]$Bindings)
    Import-Module WebAdministration
    foreach ($b in $Bindings) {
        $h, $p = $b.Split(':')
        if (Get-IisHttpsBinding -Site $Site -HostHeader $h -Port ([int]$p)) { Write-Verbose "IIS-sidos on jo olemassa: $b"; continue }
        if ($PSCmdlet.ShouldProcess("$Site $b", 'Luo IIS HTTPS -sidos (SNI)')) {
            New-WebBinding -Name $Site -Protocol https -Port ([int]$p) -HostHeader $h -SslFlags 1
            Write-Step "IIS-sidos luotu: $Site https $b (SNI)"
        }
    }
}

# Odotettu thumbprint staging-tiedostosta (avain ei tallennu: EphemeralKeySet)
function Get-StagedThumbprint {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $lines = [System.IO.File]::ReadAllLines($File)
    if ($lines.Count -lt 2) { return $null }
    $col = New-Object "$NS.X509Certificate2Collection"
    $col.Import([Convert]::FromBase64String($lines[1]), $lines[0], [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    ($col | Where-Object HasPrivateKey | Select-Object -First 1).Thumbprint
}

function Get-SslBindingHash {
    param([string]$HostPort)
    $out = & netsh.exe http show sslcert "hostnameport=$HostPort" 2>$null
    $line = $out | Where-Object { $_ -match 'Certificate Hash\s*:\s*([0-9a-fA-F]{40})' } | Select-Object -First 1
    if ($line -and $line -match '([0-9a-fA-F]{40})') { $Matches[1].ToUpperInvariant() } else { $null }
}

function Wait-CertificateInstall {
    param([pscustomobject]$Setting, [string]$InstallDir, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pending = @{}
    foreach ($n in $Setting.Certificates.Keys) { $pending[$n] = $true }
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-ScheduledTask -TaskName 'Cert-Install' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 15
        foreach ($n in @($pending.Keys)) {
            $tp = Get-StagedThumbprint (Join-Path $InstallDir "staging\$n.pfx.txt")
            if (-not $tp) { continue }
            $all = $true
            foreach ($b in $Setting.Certificates[$n]) { if ((Get-SslBindingHash $b) -ne $tp) { $all = $false } }
            if ($all) { $pending.Remove($n); Write-Step "$n asennettu ja sidottu ($tp)" }
        }
    }
    if ($pending.Count -gt 0) {
        $events = Get-EventLog -LogName Application -Source cert-install -Newest 5 -ErrorAction SilentlyContinue |
            ForEach-Object { "  $($_.TimeGenerated) $($_.EntryType): $($_.Message)" }
        throw ("Aikakatkaisu: varmenteet eivät asentuneet: $($pending.Keys -join ', ').`n" +
            "Tarkista: Get-Service vault-agent; staging-hakemisto; Application-loki (cert-install):`n" + ($events -join "`n"))
    }
}

function Test-ServedCertificate {
    param([pscustomobject]$Setting, [string]$InstallDir)
    $rows = @()
    foreach ($n in $Setting.Certificates.Keys) {
        $expected = Get-StagedThumbprint (Join-Path $InstallDir "staging\$n.pfx.txt")
        foreach ($b in $Setting.Certificates[$n]) {
            $h, $p = $b.Split(':')
            $probe = Invoke-TlsProbe -ComputerName '127.0.0.1' -Port ([int]$p) -ServerName $h -CaPath (Join-Path $InstallDir 'dvv-ca.pem')
            $tp = if ($probe.Certificate) { $probe.Certificate.Thumbprint } else { $null }
            $rows += [pscustomobject]@{
                Sidos = $b; Odotettu = $expected; Tarjoiltu = $tp
                Voimassa = if ($probe.Certificate) { $probe.Certificate.NotAfter } else { $null }
                Ok = ($probe.Ok -and $tp -eq $expected); Virhe = $probe.Error
            }
        }
    }
    $rows
}

# ----------------------------------------------------------------- pääkulku
function Invoke-InstallWindowsAgent {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Bound)
    $setting = Resolve-InstallSetting -Bound $Bound -ParameterFile $ParameterFile
    $installCertSource = Join-Path $PSScriptRoot 'Install-Cert.ps1'
    $setupSource = Join-Path $PSScriptRoot 'Setup-VaultAgent.ps1'
    $secretFile = Join-Path $InstallDir 'secret_id'
    $needToken = -not $WrappingToken -and -not (Test-Path -LiteralPath $secretFile)

    Write-Step 'Esitarkistukset (ei vielä muutoksia)'
    $checks = @(Invoke-Precheck -Setting $setting -NeedWrappingToken $needToken -InstallCertSource $installCertSource `
            -MaxClockSkewSeconds $MaxClockSkewSeconds -SkipSignatureCheck:$SkipSignatureCheck)
    $checks | Format-Table -AutoSize -Wrap | Out-String | Write-Information -InformationAction Continue
    $failed = @($checks | Where-Object { -not $_.Ok })
    if ($failed) {
        throw ("Esitarkistukset epäonnistuivat, mitään ei muutettu:`n" + (($failed | ForEach-Object { "  - $($_.Tarkistus): $($_.Korjaus)" }) -join "`n"))
    }

    $vaultExe = Install-VaultExecutable -Source $setting.VaultExeSource -Sha256 $setting.VaultExeSha256 -TargetDir $VaultInstallDir
    if ($PSCmdlet.ShouldProcess($InstallDir, 'Luo hakemisto ja kopioi tiedostot')) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        Copy-Item -LiteralPath $installCertSource -Destination (Join-Path $InstallDir 'Install-Cert.ps1') -Force
        Copy-Item -LiteralPath $setting.CaPath -Destination (Join-Path $InstallDir 'ca.pem') -Force
        Copy-Item -LiteralPath $setting.DvvCaPath -Destination (Join-Path $InstallDir 'dvv-ca.pem') -Force
    }
    $changed = $false
    $changed = (Set-FileContentIfChanged -Path (Join-Path $InstallDir 'agent.hcl') -Content (Get-AgentHclContent -Setting $setting -InstallDir $InstallDir)) -or $changed
    $changed = (Set-FileContentIfChanged -Path (Join-Path $InstallDir 'cert-install.json') -Content (Get-CertInstallJsonContent -Setting $setting -InstallDir $InstallDir)) -or $changed

    Add-IisHttpsBinding -Site $setting.IisSite -Bindings @($setting.Certificates.Values | ForEach-Object { $_ })

    # Palvelu, ACL:t ja tehtävä (palvelun SID on olemassa vasta tämän jälkeen)
    & $setupSource -Base $InstallDir -VaultExe $vaultExe -NoStart -WhatIf:$WhatIfPreference

    Set-ProtectedFile -Path (Join-Path $InstallDir 'role_id') -Content $setting.RoleId -ReaderAccount $ServiceSid
    if ($WrappingToken) {
        if ($PSCmdlet.ShouldProcess('wrapping token', 'Pura ja tallenna secret_id')) {
            $sid = Get-UnwrappedSecretId -VaultExe $vaultExe -VaultAddress $setting.VaultAddress -CaPath (Join-Path $InstallDir 'ca.pem') -WrappingToken $WrappingToken
            try { Set-ProtectedFile -Path $secretFile -Content $sid -ReaderAccount $ServiceSid } finally { $sid = $null }
            $changed = $true
            Write-Step 'secret_id tallennettu (ACL: SYSTEM, Administrators, NT SERVICE\vault-agent)'
        }
    }
    else { Write-Step 'secret_id säilytetään (ei -WrappingToken)' }

    if ($PSCmdlet.ShouldProcess($ServiceName, 'Käynnistä tai käynnistä uudelleen')) {
        $svc = Get-Service $ServiceName
        if ($svc.Status -eq 'Running' -and $changed) { Restart-Service $ServiceName }
        elseif ($svc.Status -ne 'Running') { Start-Service $ServiceName }
        Start-ScheduledTask -TaskName 'Cert-Install' -ErrorAction SilentlyContinue
    }
    if ($WhatIfPreference -or $SkipVerify) { Write-Step 'Asennuksen odotus ja TLS-todennus ohitettu'; return }

    Write-Step "Odotetaan varmenteiden asennusta (enintään $TimeoutSeconds s)"
    Wait-CertificateInstall -Setting $setting -InstallDir $InstallDir -TimeoutSeconds $TimeoutSeconds
    $rows = @(Test-ServedCertificate -Setting $setting -InstallDir $InstallDir)
    $rows | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
    if (@($rows | Where-Object { -not $_.Ok }).Count) {
        throw 'IIS ei tarjoile kaikissa sidoksissa uutta varmennetta. Katso docs/windows-liittaminen.md: "IIS tarjoilee vanhaa".'
    }
    Write-Step 'Valmis: palvelin on liitetty ja IIS tarjoilee DVV-varmennetta.'
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-InstallWindowsAgent -Bound $PSBoundParameters }
