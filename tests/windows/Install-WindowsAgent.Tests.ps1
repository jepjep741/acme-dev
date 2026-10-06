#Requires -Modules Pester
# Install-WindowsAgent.ps1: parametrit (myös JSON), konfiguraatioiden generointi, esitarkistukset,
# kääreen purku, TLS-tarkistus (oikea paikallinen TLS-palvelin) ja keskeytys ennen muutoksia.

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    # Windows-komennot, joita ei ole pwsh:ssa Linuxilla (Mock vaatii olemassa olevan komennon)
    foreach ($f in 'Get-CimInstance', 'Get-Service', 'Start-ScheduledTask', 'Get-EventLog', 'Get-AuthenticodeSignature',
        'Get-WebBinding', 'New-WebBinding', 'Restart-Service', 'Start-Service', 'Stop-Service') {
        if (-not (Get-Command $f -ErrorAction SilentlyContinue)) { Set-Item "function:global:$f" { } }
    }
    . "$PSScriptRoot/../../windows/Install-WindowsAgent.ps1"
    . "$PSScriptRoot/../../windows/Install-Cert.ps1"   # Get-CertInstallConfig: ristiintarkistus
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("iwa-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    $script:rid = '0b4e2b8e-3a9c-4c1e-9f0d-6b1f2a3c4d5e'
    $script:sha = 'e07a39059d7c7380d6dc776fb5bee2183cbc3344cf9387d4cf11309b83c0dce3'
    $script:valid = @{
        VaultAddress = 'https://vault.asiakas.fi:8200'; RoleId = $script:rid
        Certificates = @{ intranet = @('intranet.asiakas.fi:443'); api = @('api.asiakas.fi:443', 'api2.asiakas.fi:8443') }
        CaPath = 'C:\x\ca.pem'; DvvCaPath = 'C:\x\dvv-ca.pem'; VaultExeSource = 'C:\x\vault.exe'; VaultExeSha256 = $script:sha
    }
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Resolve-InstallSetting' {
    It 'komentorivin parametrit + oletukset (NoCheck, Warn, 7 pv, Default Web Site)' {
        $s = Resolve-InstallSetting -Bound $script:valid -ParameterFile $null
        $s.RevocationMode | Should -Be 'NoCheck'
        $s.CrlStalePolicy | Should -Be 'Warn'
        $s.MinValidDays | Should -Be 7
        $s.IisSite | Should -Be 'Default Web Site'
        @($s.Certificates.Keys) | Should -Be @('api', 'intranet')
    }
    It 'lukee JSON-parametritiedoston (onboard-server.sh csv), suhteelliset polut tiedoston hakemistoon' {
        $p = Join-Path $script:tmp 'web01.json'
        @{ Server = 'web01'; VaultAddress = 'https://vault.asiakas.fi:8200'; RoleId = $script:rid
            Certificates = @{ intranet = @('intranet.asiakas.fi:443') }; CaPath = 'ca.pem'; DvvCaPath = 'dvv-ca.pem'
            VaultExeSource = 'bin/vault.exe'; VaultExeSha256 = $script:sha; RevocationMode = 'Offline'
        } | ConvertTo-Json -Depth 4 | Set-Content $p
        $s = Resolve-InstallSetting -Bound @{} -ParameterFile $p
        $s.Server | Should -Be 'web01'
        $s.RevocationMode | Should -Be 'Offline'
        $s.CaPath | Should -Be (Join-Path $script:tmp 'ca.pem')
        $s.VaultExeSource | Should -Be (Join-Path $script:tmp 'bin/vault.exe')
        $s.Certificates['intranet'] | Should -Be @('intranet.asiakas.fi:443')
    }
    It 'komentorivi ohittaa parametritiedoston' {
        $p = Join-Path $script:tmp 'web02.json'
        @{ VaultAddress = 'https://vanha:8200'; RoleId = $script:rid; Certificates = @{ a = @('a.x:443') }
            CaPath = 'c'; DvvCaPath = 'd'; VaultExeSource = 'v'; VaultExeSha256 = $script:sha } | ConvertTo-Json | Set-Content $p
        (Resolve-InstallSetting -Bound @{ VaultAddress = 'https://uusi.asiakas.fi:8200' } -ParameterFile $p).VaultAddress |
            Should -Be 'https://uusi.asiakas.fi:8200'
    }
    It 'hylkää parametritiedoston, jossa on salaisuus' {
        $p = Join-Path $script:tmp 'leak.json'
        '{"WrappingToken":"hvs.x","RoleId":"x"}' | Set-Content $p
        { Resolve-InstallSetting -Bound @{} -ParameterFile $p } | Should -Throw '*salaisuuksia*'
    }
    It 'listaa kaikki virheet kerralla' {
        $b = $script:valid.Clone()
        $b.RoleId = 'ei-uuid'; $b.VaultAddress = 'http://vault:8200'; $b.Certificates = @{ 'Iso_Nimi' = @('eiportti') }; $b.VaultExeSha256 = 'abc'
        $err = { Resolve-InstallSetting -Bound $b -ParameterFile $null } | Should -Throw -PassThru
        $m = $err.Exception.Message
        $m | Should -BeLike '*RoleId*'
        $m | Should -BeLike '*VaultAddress*'
        $m | Should -BeLike "*varmenteen nimi 'Iso_Nimi'*"
        $m | Should -BeLike "*sidos 'eiportti'*"
        $m | Should -BeLike '*VaultExeSha256*'
    }
}

Describe 'Konfiguraatioiden generointi' {
    BeforeAll { $script:s = Resolve-InstallSetting -Bound $script:valid -ParameterFile $null }
    It 'agent.hcl: oma template jokaiselle varmenteelle, polut /-muodossa, ei salaisuuksia' {
        $h = Get-AgentHclContent -Setting $script:s -InstallDir 'C:\ProgramData\vault-agent'
        $h | Should -Match 'address = "https://vault.asiakas.fi:8200"'
        $h | Should -Match 'ca_cert = "C:/ProgramData/vault-agent/ca.pem"'
        $h | Should -Match 'secret/data/certs/intranet'
        $h | Should -Match 'secret/data/certs/api'
        $h | Should -Match 'destination +\= "C:/ProgramData/vault-agent/staging/api.pfx.txt"'
        $h | Should -Match 'remove_secret_id_file_after_reading = false'
        $h | Should -Not -Match '\\\\'
        ([regex]::Matches($h, 'template \{')).Count | Should -Be 2
    }
    It 'cert-install.json kelpaa Install-Cert.ps1:lle (ristiintarkistus)' {
        $j = Get-CertInstallJsonContent -Setting $script:s -InstallDir 'C:\ProgramData\vault-agent'
        $p = Join-Path $script:tmp 'cert-install.json'; $j | Set-Content $p
        $c = Get-CertInstallConfig -Path $p
        $c.RevocationMode | Should -Be 'NoCheck'
        @($c.Certificates.api) | Should -Be @('api.asiakas.fi:443', 'api2.asiakas.fi:8443')
    }
    It 'Set-FileContentIfChanged kirjoittaa vain muuttuneen sisällön (idempotentti)' {
        $p = Join-Path $script:tmp 'idem.txt'
        Set-FileContentIfChanged -Path $p -Content 'a' | Should -BeTrue
        Set-FileContentIfChanged -Path $p -Content 'a' | Should -BeFalse
        Set-FileContentIfChanged -Path $p -Content 'b' | Should -BeTrue
    }
}

Describe 'Invoke-Precheck' {
    BeforeEach {
        $script:s = Resolve-InstallSetting -Bound $script:valid -ParameterFile $null
        Mock Test-IsAdministrator { $true }
        Mock Get-OsInfo { [pscustomobject]@{ Caption = 'Windows Server 2022'; Build = 20348; ProductType = 3 } }
        Mock Get-DotNetRelease { 528449 }
        Mock Test-IisInstalled { $true }
        Mock Test-Path { $true }
        Mock Get-FileSha256 { $script:sha }
        Mock Test-TcpPort { $true }
        Mock Invoke-TlsProbe { [pscustomobject]@{ Ok = $true; Error = $null; StatusCode = 200; Date = (Get-Date).ToUniversalTime(); Certificate = $null } }
        Mock Test-ScriptSigned { $true }
    }
    It 'kaikki kunnossa' {
        $r = Invoke-Precheck -Setting $script:s -NeedWrappingToken $false -InstallCertSource 'x' -MaxClockSkewSeconds 60
        @($r | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        @($r).Count | Should -BeGreaterOrEqual 11
    }
    It 'vanha .NET, sinetöity Vault, kellon poikkeama, allekirjoitus ja puuttuva kääre havaitaan' {
        Mock Get-DotNetRelease { 394802 }
        Mock Invoke-TlsProbe { [pscustomobject]@{ Ok = $true; Error = $null; StatusCode = 503; Date = (Get-Date).ToUniversalTime().AddMinutes(-3); Certificate = $null } }
        Mock Test-ScriptSigned { $false }
        $r = Invoke-Precheck -Setting $script:s -NeedWrappingToken $true -InstallCertSource 'x' -MaxClockSkewSeconds 60
        $failed = @($r | Where-Object { -not $_.Ok }).Tarkistus
        $failed | Should -Contain '.NET Framework >= 4.7.2'
        $failed | Should -Contain 'Vaultin tila'
        $failed | Should -Contain 'Kellon poikkeama Vaultiin'
        $failed | Should -Contain 'Install-Cert.ps1 allekirjoitettu'
        $failed | Should -Contain 'Wrapping token'
        ($r | Where-Object Tarkistus -EQ 'Vaultin tila').Tulos | Should -Be 'SINETÖITY'
    }
    It 'Server 2016: hyväksytään, muistutus PFX_COMPAT=legacy' {
        Mock Get-OsInfo { [pscustomobject]@{ Caption = 'Windows Server 2016'; Build = 14393; ProductType = 3 } }
        $r = Invoke-Precheck -Setting $script:s -NeedWrappingToken $false -InstallCertSource 'x' -MaxClockSkewSeconds 60 -SkipSignatureCheck
        ($r | Where-Object Tarkistus -EQ 'Käyttöjärjestelmä').Ok | Should -BeTrue
        ($r | Where-Object Tarkistus -EQ 'Käyttöjärjestelmä').Tulos | Should -BeLike '*PFX_COMPAT=legacy*'
    }
    It 'väärä vault.exe ja Vault ei vastaa' {
        Mock Get-FileSha256 { '0' * 64 }
        Mock Test-TcpPort { $false }
        $r = Invoke-Precheck -Setting $script:s -NeedWrappingToken $false -InstallCertSource 'x' -MaxClockSkewSeconds 60
        $failed = @($r | Where-Object { -not $_.Ok }).Tarkistus
        $failed | Should -Contain 'vault.exe SHA256'
        $failed | Should -Contain 'Yhteys Vaultiin (TCP)'
        Should -Invoke Invoke-TlsProbe -Times 0
    }
}

Describe 'Invoke-InstallWindowsAgent: keskeytys ennen muutoksia' {
    It 'epäonnistunut esitarkistus ei tee mitään muutoksia' {
        $script:ParameterFile = $null; $script:WrappingToken = $null
        Mock Invoke-Precheck { Get-CheckResult -Name 'IIS' -Ok $false -Message 'puuttuu' -Fix 'Install-WindowsFeature Web-Server' }
        Mock Install-VaultExecutable { throw 'ei saa kutsua' }
        Mock Set-FileContentIfChanged { throw 'ei saa kutsua' }
        Mock Set-ProtectedFile { throw 'ei saa kutsua' }
        Mock Add-IisHttpsBinding { throw 'ei saa kutsua' }
        Mock Format-Table { }
        { Invoke-InstallWindowsAgent -Bound $script:valid } | Should -Throw '*mitään ei muutettu*IIS*Install-WindowsFeature*'
        Should -Invoke Install-VaultExecutable -Times 0
        Should -Invoke Set-ProtectedFile -Times 0
    }
}

Describe 'Get-UnwrappedSecretId' {
    BeforeAll { $script:tok = ConvertTo-SecureString 'hvs.CAES-kaare' -AsPlainText -Force }
    It 'token kulkee vain lapsiprosessin ympäristössä, ei argumenteissa' {
        Mock Invoke-VaultCli { [pscustomobject]@{ ExitCode = 0; StdOut = "s3cr3t-id`n"; StdErr = '' } }
        Get-UnwrappedSecretId -VaultExe 'vault.exe' -VaultAddress 'https://v:8200' -CaPath 'ca.pem' -WrappingToken $script:tok | Should -Be 's3cr3t-id'
        Should -Invoke Invoke-VaultCli -Times 1 -ParameterFilter {
            $Environment.VAULT_TOKEN -eq 'hvs.CAES-kaare' -and ($Arguments -join ' ') -notmatch 'hvs\.' -and $Arguments -contains 'unwrap'
        }
    }
    It 'käytetty tai vanhentunut kääre: keskeytys ja vuotovaroitus' {
        Mock Invoke-VaultCli { [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = '* wrapping token is not valid or does not exist' } }
        { Get-UnwrappedSecretId -VaultExe 'vault.exe' -VaultAddress 'https://v:8200' -CaPath 'ca.pem' -WrappingToken $script:tok } |
            Should -Throw '*siepata*onboard-server.sh wrap*'
    }
}

Describe 'Invoke-TlsProbe (oikea TLS-palvelin)' {
    BeforeAll {
        $script:ca = New-TestCa -Name 'Vault internal CA'
        $script:srv = New-TestLeaf -DnsName 'vault.asiakas.fi' -Issuer $script:ca
        $script:caPem = Join-Path $script:tmp 'vault-ca.pem'; ConvertTo-Pem $script:ca | Set-Content $script:caPem
        $script:pfxSrv = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($script:srv.Export('Pfx'))
    }
    It 'luottaa annettuun CA:han, lukee HTTP-tilan ja Date-otsakkeen' {
        $d = (Get-Date).ToUniversalTime().AddSeconds(-90)
        $t = Start-TestTlsServer -Certificate $script:pfxSrv -StatusCode 503 -Date $d
        try { $r = Invoke-TlsProbe -ComputerName 127.0.0.1 -Port $t.Port -ServerName 'vault.asiakas.fi' -CaPath $script:caPem -HttpPath '/v1/sys/health' }
        finally { Stop-TestTlsServer $t }
        $r.Ok | Should -BeTrue
        $r.StatusCode | Should -Be 503
        [math]::Abs(($r.Date - $d).TotalSeconds) | Should -BeLessThan 2
        $r.Certificate.Thumbprint | Should -Be $script:srv.Thumbprint
    }
    It 'hylkää varmenteen, jota annettu CA ei ole myöntänyt' {
        $otherPem = Join-Path $script:tmp 'other.pem'; ConvertTo-Pem (New-TestCa -Name 'Muu CA') | Set-Content $otherPem
        $t = Start-TestTlsServer -Certificate $script:pfxSrv
        try { $r = Invoke-TlsProbe -ComputerName 127.0.0.1 -Port $t.Port -ServerName 'vault.asiakas.fi' -CaPath $otherPem }
        finally { Stop-TestTlsServer $t }
        $r.Ok | Should -BeFalse
        $r.Error | Should -BeLike '*annetun CA:n*'
    }
    It 'hylkää, jos nimi ei täsmää' {
        $t = Start-TestTlsServer -Certificate $script:pfxSrv
        try { $r = Invoke-TlsProbe -ComputerName 127.0.0.1 -Port $t.Port -ServerName 'vaara.asiakas.fi' -CaPath $script:caPem }
        finally { Stop-TestTlsServer $t }
        $r.Ok | Should -BeFalse
        $r.Error | Should -BeLike '*nimi*'
    }
}

Describe 'Get-StagedThumbprint' {
    It 'laskee odotetun thumbprintin staging-tiedostosta (avainta ei tallenneta)' {
        $c = New-TestChain
        $col = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        $col.Add($c.Leaf) | Out-Null; $col.Add($c.Intermediate) | Out-Null
        $f = Join-Path $script:tmp 'web.pfx.txt'
        "pw-1`n" + [Convert]::ToBase64String($col.Export('Pkcs12', 'pw-1')) | Set-Content -NoNewline $f
        Get-StagedThumbprint -File $f | Should -Be $c.Leaf.Thumbprint
        Get-StagedThumbprint -File (Join-Path $script:tmp 'puuttuu.txt') | Should -BeNullOrEmpty
    }
}
