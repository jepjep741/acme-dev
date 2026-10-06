# Vault Agent -palvelu ja Cert-Install-tehtävä. Ajetaan järjestelmänvalvojana (yleensä
# Install-WindowsAgent.ps1:n kautta). Toimii Windows PowerShell 5.1:llä. Idempotentti.
# Olettaa: vault.exe -> $VaultExe; Install-Cert.ps1, agent.hcl, cert-install.json, ca.pem, dvv-ca.pem
#          hakemistossa $Base (role_id ja secret_id kirjoittaa Install-WindowsAgent.ps1).
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Base = 'C:\ProgramData\vault-agent',
    [string]$VaultExe = 'C:\Program Files\Vault\vault.exe',
    # Älä käynnistä palvelua (Install-WindowsAgent kirjoittaa tunnisteet ensin)
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
$Svc = 'vault-agent'
$SvcSid = "NT SERVICE\$Svc"

foreach ($d in 'staging', 'run') {
    if (-not (Test-Path "$Base\$d") -and $PSCmdlet.ShouldProcess("$Base\$d", 'Luo hakemisto')) {
        New-Item -ItemType Directory -Force -Path "$Base\$d" | Out-Null
    }
}

# 1) Palvelu virtuaalitilillä
$binPath = "`"$VaultExe`" agent -config=`"$Base\agent.hcl`""
if (-not (Get-Service $Svc -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($Svc, 'Luo palvelu')) {
        New-Service -Name $Svc -DisplayName 'Vault Agent (varmenteet)' -StartupType Automatic -BinaryPathName $binPath | Out-Null
    }
}
if ($PSCmdlet.ShouldProcess($Svc, "Aseta tili $SvcSid ja uudelleenkäynnistys")) {
    sc.exe config $Svc obj= $SvcSid binPath= $binPath | Out-Null
    sc.exe failure $Svc reset= 86400 actions= restart/60000/restart/60000/restart/300000 | Out-Null
}

# 2) ACL:t, periytys pois. Perusasetukset: vain SYSTEM + Administrators.
function Set-DirectoryAcl {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [string[]]$Rules)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in $Rules) {
        $id, $right = $r.Split('|')
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $id, $right, 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Aseta ACL')) { Set-Acl -Path $Path -AclObject $acl }
}
Set-DirectoryAcl $Base @('SYSTEM|FullControl', 'BUILTIN\Administrators|FullControl', "$SvcSid|ReadAndExecute")
Set-DirectoryAcl "$Base\staging" @('SYSTEM|FullControl', 'BUILTIN\Administrators|FullControl', "$SvcSid|Modify")
Set-DirectoryAcl "$Base\run" @('SYSTEM|FullControl', 'BUILTIN\Administrators|FullControl', "$SvcSid|Modify")

# 3) Tapahtumalokin lähde
if (-not [System.Diagnostics.EventLog]::SourceExists('cert-install') -and $PSCmdlet.ShouldProcess('cert-install', 'Luo tapahtumalähde')) {
    New-EventLog -LogName Application -Source 'cert-install'
}

# 4) Asennustehtävä SYSTEMinä: käynnistyksessä ja 15 min välein
$act = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy AllSigned -File `"$Base\Install-Cert.ps1`""
# RepetitionDuration annetaan aina: oletus vaihtelee Windows-versioittain (2016: 1 vrk)
$trig = @( (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)) )
$prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
if ($PSCmdlet.ShouldProcess('Cert-Install', 'Rekisteröi ajastettu tehtävä')) {
    Register-ScheduledTask -TaskName 'Cert-Install' -Action $act -Trigger $trig -Principal $prin -Settings $set -Force | Out-Null
}

if (-not $NoStart -and $PSCmdlet.ShouldProcess($Svc, 'Käynnistä palvelu')) {
    Start-Service $Svc
    Write-Output 'Valmis. Huom: -ExecutionPolicy AllSigned edellyttää, että Install-Cert.ps1 on allekirjoitettu.'
}
