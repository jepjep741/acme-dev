# C:\ProgramData\vault-agent\Install-Cert.ps1  -  ajetaan SYSTEMinä ajastetusti.
# Asentaa keskuspalvelimen valmiiksi tekemän PFX:n tarkistusten jälkeen.
# Toimii Windows PowerShell 5.1:llä (.NET Framework 4.7.2+) ja PowerShell 7:llä.
$ErrorActionPreference = 'Stop'
$Base = 'C:\ProgramData\vault-agent'
$cfg  = Get-Content "$Base\cert-install.json" -Raw | ConvertFrom-Json
$IisAppId = '{4dc3e181-e14b-4a21-b022-59fc669b0914}'
$NS = 'System.Security.Cryptography.X509Certificates'
function Log($type, $msg) {
  Write-EventLog -LogName Application -Source 'cert-install' -EventId 100 -EntryType $type -Message $msg
}

$dvvRoot = New-Object "$NS.X509Certificate2" "$Base\dvv-ca.pem"
$my = New-Object "$NS.X509Store" 'My','LocalMachine';  $my.Open('ReadWrite')
$ca = New-Object "$NS.X509Store" 'CA','LocalMachine';  $ca.Open('ReadWrite')

foreach ($entry in $cfg.Certificates.PSObject.Properties) {
  $name = $entry.Name; $bindings = @($entry.Value)
  $file = Join-Path $cfg.StagingDir "$name.pfx.txt"
  if (-not (Test-Path $file)) { continue }
  try {
    $lines = [System.IO.File]::ReadAllLines($file)
    if ($lines.Count -lt 2) { throw "tiedosto on vajaa" }
    $pw    = $lines[0]
    $bytes = [Convert]::FromBase64String($lines[1])

    # Tarkistus avaimella, joka EI tallennu koneelle (EphemeralKeySet)
    $all = New-Object "$NS.X509Certificate2Collection"
    $all.Import($bytes, $pw, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    $leaf = $all | Where-Object HasPrivateKey | Select-Object -First 1
    if (-not $leaf) { throw "PFX:ssä ei ole yksityistä avainta" }
    if ($my.Certificates.Find('FindByThumbprint', $leaf.Thumbprint, $false).Count -gt 0) { continue }  # jo asennettu

    # 1) Ketju DVV:n juureen. Tarkistetaan, että ketjun viimeinen elementti on NIMENOMAAN DVV:n juuri.
    $chain = New-Object "$NS.X509Chain"
    $chain.ChainPolicy.ExtraStore.AddRange($all)
    $chain.ChainPolicy.ExtraStore.Add($dvvRoot) | Out-Null
    $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
    $chain.ChainPolicy.RevocationMode = 'Online'
    $chain.ChainPolicy.RevocationFlag = 'ExcludeRoot'
    $null = $chain.Build($leaf)
    $top  = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
    if ($top.Thumbprint -ne $dvvRoot.Thumbprint) { throw "ketju ei päädy DVV:n juureen" }
    $bad = $chain.ChainStatus | Where-Object { $_.Status -ne 'UntrustedRoot' -and $_.Status -ne 'NoError' }
    if ($bad) { throw "ketjuvirhe: " + (($bad | ForEach-Object Status) -join ', ') }

    # 2) Voimassaolo ja 3) ei vanhempi kuin nykyinen
    if ($leaf.NotAfter -lt (Get-Date).AddDays($cfg.MinValidDays)) { throw "vanhenee pian ($($leaf.NotAfter))" }
    $current = $my.Certificates | Where-Object Subject -eq $leaf.Subject | Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($current -and $leaf.NotAfter -lt $current.NotAfter) { throw "vanhempi kuin nykyinen varmenne" }

    # Tuonti: avain koneen avainsäilöön, EI vietävissä (ei Exportable-lippua)
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes, $pw,
              [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]'MachineKeySet,PersistKeySet')
    $my.Add($cert)
    # Välivarmenteet Intermediate-säilöön, jotta IIS lähettää koko ketjun
    $all | Where-Object { -not $_.HasPrivateKey -and $_.Subject -ne $_.Issuer } | ForEach-Object { $ca.Add($_) }

    foreach ($hp in $bindings) {
      netsh http update sslcert hostnameport=$hp certhash=$($cert.Thumbprint) appid=$IisAppId certstorename=MY | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "sidoksen päivitys epäonnistui: $hp" }
    }
    $my.Certificates | Where-Object { $_.Subject -eq $cert.Subject -and $_.Thumbprint -ne $cert.Thumbprint } |
      ForEach-Object { $my.Remove($_) }

    Log Information "$name asennettu: $($cert.Thumbprint), voimassa $($cert.NotAfter) asti, sidokset: $($bindings -join ', ')"
  }
  catch {
    Log Error "$name hylätty, vanha varmenne jää voimaan: $($_.Exception.Message)"
  }
  finally {
    $pw = $null; $bytes = $null
  }
}
$my.Close(); $ca.Close()
