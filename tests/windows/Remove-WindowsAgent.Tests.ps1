#Requires -Modules Pester
# Remove-WindowsAgent.ps1: tunnisteiden hävitys, Vault-puolen ohjeet, varmenteet jätetään oletuksena.

BeforeAll {
    foreach ($f in 'Get-Service', 'Stop-Service', 'Get-ScheduledTask', 'Unregister-ScheduledTask') {
        if (-not (Get-Command $f -ErrorAction SilentlyContinue)) { Set-Item "function:global:$f" { } }
    }
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rwa-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path (Join-Path $script:tmp 'staging') -Force | Out-Null
    $env:COMPUTERNAME = 'WEB01'
    . "$PSScriptRoot/../../windows/Remove-WindowsAgent.ps1"
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Invoke-RemoveWindowsAgent' {
    It 'hävittää secret_id:n, role_id:n ja staging-tiedostot; tulostaa Vault-komennon; varmenteet jäävät' {
        'salainen-id' | Set-Content (Join-Path $script:tmp 'secret_id')
        'rooli' | Set-Content (Join-Path $script:tmp 'role_id')
        'pw' | Set-Content (Join-Path $script:tmp 'staging/web.pfx.txt')
        Mock Remove-AgentService { }
        Mock Remove-ManagedCertificate { }
        $out = Invoke-RemoveWindowsAgent -Server web01 -InstallDir $script:tmp -VaultInstallDir $script:tmp 6>$null
        Test-Path (Join-Path $script:tmp 'secret_id') | Should -BeFalse
        Test-Path (Join-Path $script:tmp 'role_id') | Should -BeFalse
        Test-Path (Join-Path $script:tmp 'staging/web.pfx.txt') | Should -BeFalse
        ($out -join "`n") | Should -BeLike '*onboard-server.sh remove web01*'
        ($out -join "`n") | Should -BeLike '*-RemoveCertificates*'
        Should -Invoke Remove-AgentService -Times 1
        Should -Invoke Remove-ManagedCertificate -Times 0
    }
    It '-RemoveCertificates poistaa myös hallitut varmenteet' {
        Mock Remove-AgentService { }
        Mock Remove-ManagedCertificate { }
        $null = Invoke-RemoveWindowsAgent -Server web01 -InstallDir $script:tmp -VaultInstallDir $script:tmp -RemoveCertificates 6>$null
        Should -Invoke Remove-ManagedCertificate -Times 1
    }
    It 'hylkää virheellisen palvelinnimen' {
        { Invoke-RemoveWindowsAgent -Server 'Web 01' -InstallDir $script:tmp -VaultInstallDir $script:tmp } | Should -Throw '*ei kelpaa*'
    }
    It '-WhatIf ei poista mitään' {
        'x' | Set-Content (Join-Path $script:tmp 'secret_id')
        Mock Remove-AgentService { }
        $null = Invoke-RemoveWindowsAgent -Server web01 -InstallDir $script:tmp -VaultInstallDir $script:tmp -WhatIf 6>$null
        Test-Path (Join-Path $script:tmp 'secret_id') | Should -BeTrue
    }
}

Describe 'Remove-SensitiveFile' {
    It 'ylikirjoittaa ennen poistoa' {
        $p = Join-Path $script:tmp 'sens.txt'; 'salaisuus' | Set-Content $p
        Mock Remove-Item { $script:contentAtDelete = [System.IO.File]::ReadAllBytes($LiteralPath) } -ParameterFilter { $LiteralPath -eq $p }
        Remove-SensitiveFile -Path $p 6>$null
        [System.Text.Encoding]::UTF8.GetString($script:contentAtDelete) | Should -Not -BeLike '*salaisuus*'
    }
}
