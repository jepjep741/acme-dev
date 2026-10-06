# Ajetaan kerran järjestelmänvalvojana (esim. Ansiblella). Toimii Windows PowerShell 5.1:llä.
# Olettaa: vault.exe  -> C:\Program Files\Vault\vault.exe
#          Install-Cert.ps1, agent.hcl, cert-install.json, ca.pem, dvv-ca.pem, role_id, secret_id
#          on kopioitu hakemistoon C:\ProgramData\vault-agent\
$ErrorActionPreference = 'Stop'
$Base    = 'C:\ProgramData\vault-agent'
$Svc     = 'vault-agent'
$SvcSid  = "NT SERVICE\$Svc"
$Vault   = 'C:\Program Files\Vault\vault.exe'

foreach ($d in 'staging','run') { New-Item -ItemType Directory -Force -Path "$Base\$d" | Out-Null }

# 1) Palvelu virtuaalitilillä
if (-not (Get-Service $Svc -ErrorAction SilentlyContinue)) {
  New-Service -Name $Svc -DisplayName 'Vault Agent (varmenteet)' -StartupType Automatic `
    -BinaryPathName "`"$Vault`" agent -config=`"$Base\agent.hcl`"" | Out-Null
}
sc.exe config $Svc obj= $SvcSid | Out-Null
sc.exe failure $Svc reset= 86400 actions= restart/60000/restart/60000/restart/300000 | Out-Null

# 2) ACL:t, periytys pois. Perusasetukset: vain SYSTEM + Administrators.
function Set-Acl2($Path, [string[]]$Rules) {
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($r in $Rules) {
    $id,$right = $r.Split('|')
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
      $id, $right, 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
  }
  Set-Acl -Path $Path -AclObject $acl
}
Set-Acl2 $Base            @('SYSTEM|FullControl','BUILTIN\Administrators|FullControl',"$SvcSid|ReadAndExecute")
Set-Acl2 "$Base\staging"  @('SYSTEM|FullControl','BUILTIN\Administrators|FullControl',"$SvcSid|Modify")
Set-Acl2 "$Base\run"      @('SYSTEM|FullControl','BUILTIN\Administrators|FullControl',"$SvcSid|Modify")

# 3) Tapahtumalokin lähde
if (-not [System.Diagnostics.EventLog]::SourceExists('cert-install')) {
  New-EventLog -LogName Application -Source 'cert-install'
}

# 4) Asennustehtävä SYSTEMinä: käynnistyksessä ja 15 min välein
$act  = New-ScheduledTaskAction -Execute 'powershell.exe' `
          -Argument "-NoProfile -NonInteractive -ExecutionPolicy AllSigned -File `"$Base\Install-Cert.ps1`""
$trig = @( (New-ScheduledTaskTrigger -AtStartup),
           (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)) )
$prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$set  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'Cert-Install' -Action $act -Trigger $trig -Principal $prin -Settings $set -Force | Out-Null

Start-Service $Svc
Write-Host "Valmis. Huom: -ExecutionPolicy AllSigned edellyttää, että Install-Cert.ps1 on allekirjoitettu."
