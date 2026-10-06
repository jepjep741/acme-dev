#Requires -Modules Pester
# Install-Cert.ps1: konfiguraatio, ketjun tarkistus (oikeat testivarmenteet), sidosten luonti/korjaus,
# vanhojen varmenteiden rajaus. Windows-komennot (netsh, Event Log) mockataan.

BeforeAll {
    . "$PSScriptRoot/TestHelpers.ps1"
    function Write-EventLog { param($LogName, $Source, $EventId, $EntryType, $Message) }
    . "$PSScriptRoot/../../windows/Install-Cert.ps1"
    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ic-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
}
AfterAll { Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

Describe 'Get-CertInstallConfig' {
    It 'puuttuva RevocationMode = Online (vanhat asennukset toimivat ennallaan)' {
        $p = Join-Path $script:tmp 'old.json'
        '{"StagingDir":"C:\\x","MinValidDays":7,"Certificates":{"intranet":["intranet.example:443"]}}' | Set-Content $p
        $c = Get-CertInstallConfig -Path $p
        $c.RevocationMode | Should -Be 'Online'
        $c.CrlStalePolicy | Should -Be 'Warn'
    }
    It 'hyväksyy Offline/NoCheck ja Fail' {
        $p = Join-Path $script:tmp 'new.json'
        '{"StagingDir":"x","MinValidDays":7,"RevocationMode":"NoCheck","CrlStalePolicy":"Fail","Certificates":{}}' | Set-Content $p
        (Get-CertInstallConfig -Path $p).RevocationMode | Should -Be 'NoCheck'
        (Get-CertInstallConfig -Path $p).CrlStalePolicy | Should -Be 'Fail'
    }
    It 'hylkää tuntemattoman RevocationMode-arvon' {
        $p = Join-Path $script:tmp 'bad.json'
        '{"StagingDir":"x","MinValidDays":7,"RevocationMode":"Maybe","Certificates":{}}' | Set-Content $p
        { Get-CertInstallConfig -Path $p } | Should -Throw '*RevocationMode*'
    }
}

Describe 'Test-CertChain' {
    BeforeAll {
        $script:ch = New-TestChain
        $script:extra = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        $script:extra.Add($script:ch.Intermediate) | Out-Null
    }
    It 'kelpuuttaa ketjun, joka päätyy DVV:n juureen (NoCheck)' {
        $r = Test-CertChain -Leaf $script:ch.Leaf -Extra $script:extra -TrustedRoot $script:ch.Root -RevocationMode NoCheck -CrlStalePolicy Warn
        $r.Ok | Should -BeTrue
    }
    It 'hylkää ketjun, joka päätyy eri juureen' {
        $other = New-TestCa -Name 'Muu juuri'
        $r = Test-CertChain -Leaf $script:ch.Leaf -Extra $script:extra -TrustedRoot $other -RevocationMode NoCheck -CrlStalePolicy Warn
        $r.Ok | Should -BeFalse
        $r.Error | Should -Be 'ketju ei päädy DVV:n juureen'
    }
    It 'hylkää vanhentuneen varmenteen' {
        $exp = New-TestLeaf -DnsName 'old.example.test' -Issuer $script:ch.Intermediate -Expired
        $r = Test-CertChain -Leaf $exp -Extra $script:extra -TrustedRoot $script:ch.Root -RevocationMode NoCheck -CrlStalePolicy Warn
        $r.Ok | Should -BeFalse
        $r.Error | Should -BeLike '*NotTimeValid*'
    }
    It 'Offline ilman CRL:ää: Warn -> hyväksytään varoituksin, Fail -> hylätään' {
        $w = Test-CertChain -Leaf $script:ch.Leaf -Extra $script:extra -TrustedRoot $script:ch.Root -RevocationMode Offline -CrlStalePolicy Warn
        $w.Ok | Should -BeTrue
        $w.Warnings.Count | Should -BeGreaterThan 0
        $f = Test-CertChain -Leaf $script:ch.Leaf -Extra $script:extra -TrustedRoot $script:ch.Root -RevocationMode Offline -CrlStalePolicy Fail
        $f.Ok | Should -BeFalse
        $f.Error | Should -BeLike '*Revocation*'
    }
}

Describe 'Get-SupersededCert' {
    It 'poistaa vain saman Subjectin JA saman myöntäjän vanhat varmenteet' {
        $a = New-TestChain -DnsName 'web.example.test'
        $old = New-TestLeaf -DnsName 'web.example.test' -Issuer $a.Intermediate
        $new = New-TestLeaf -DnsName 'web.example.test' -Issuer $a.Intermediate
        $otherIssuer = New-TestLeaf -DnsName 'web.example.test' -Issuer (New-TestCa -Name 'Toinen CA' -Days 400)
        $res = Get-SupersededCert -StoreCerts @($old, $new, $otherIssuer) -New $new
        $res.Count | Should -Be 1
        $res[0].Thumbprint | Should -Be $old.Thumbprint
    }
}

Describe 'Set-SslBinding' {
    It 'luo puuttuvan sidoksen (add)' {
        Mock Invoke-Netsh { $script:NetshExit = 1; 'The system cannot find the file specified.' } -ParameterFilter { $Arguments[1] -eq 'show' }
        Mock Invoke-Netsh { $script:NetshExit = 0 } -ParameterFilter { $Arguments[1] -eq 'add' }
        Set-SslBinding -HostPort 'web.example.test:443' -Thumbprint ('A' * 40) | Should -Be 'added'
        Should -Invoke Invoke-Netsh -ParameterFilter { $Arguments[1] -eq 'add' -and $Arguments -contains "certhash=$('A' * 40)" } -Times 1
    }
    It 'päivittää vanhaan varmenteeseen osoittavan sidoksen (update)' {
        Mock Invoke-Netsh { $script:NetshExit = 0; "    Certificate Hash             : $('b' * 40)" } -ParameterFilter { $Arguments[1] -eq 'show' }
        Mock Invoke-Netsh { $script:NetshExit = 0 } -ParameterFilter { $Arguments[1] -eq 'update' }
        Set-SslBinding -HostPort 'web.example.test:443' -Thumbprint ('A' * 40) | Should -Be 'updated'
    }
    It 'ei muuta oikeaan varmenteeseen osoittavaa sidosta' {
        Mock Invoke-Netsh { $script:NetshExit = 0; "    Certificate Hash             : $('a' * 40)" }
        Set-SslBinding -HostPort 'web.example.test:443' -Thumbprint ('A' * 40) | Should -Be 'unchanged'
        Should -Invoke Invoke-Netsh -Times 1
    }
    It 'heittää, jos netsh epäonnistuu' {
        Mock Invoke-Netsh { $script:NetshExit = 1 }
        { Set-SslBinding -HostPort 'x:443' -Thumbprint ('A' * 40) } | Should -Throw '*epäonnistui*'
    }
}

Describe 'Install-StagedCertificate' {
    BeforeAll {
        $script:chain = New-TestChain -DnsName 'web.example.test'
        $col = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        $col.Add($script:chain.Leaf) | Out-Null; $col.Add($script:chain.Intermediate) | Out-Null
        $pfx = $col.Export('Pkcs12', 'salasana-123')
        $script:staging = Join-Path $script:tmp 'staging'; New-Item -ItemType Directory $script:staging -Force | Out-Null
        "salasana-123`n" + [Convert]::ToBase64String($pfx) | Set-Content -NoNewline (Join-Path $script:staging 'web.pfx.txt')
        $script:cfg = [pscustomobject]@{ StagingDir = $script:staging; MinValidDays = 7; RevocationMode = 'NoCheck'; CrlStalePolicy = 'Warn' }
    }
    It 'jo asennettu varmenne: korjaa puuttuvan sidoksen eikä tuo uudelleen' {
        $my = [pscustomobject]@{ Certificates = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection) }
        $my.Certificates.Add([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($script:chain.Leaf.RawData)) | Out-Null
        Mock Set-SslBinding { 'added' }
        Mock Write-CertLog { }
        Install-StagedCertificate -Cfg $script:cfg -Name web -Bindings @('web.example.test:443') -DvvRoot $script:chain.Root -My $my -Ca $null
        Should -Invoke Set-SslBinding -Times 1 -ParameterFilter { $Thumbprint -eq $script:chain.Leaf.Thumbprint }
        Should -Invoke Write-CertLog -Times 1 -ParameterFilter { $Type -eq 'Warning' -and $Message -like '*korjattu*' }
    }
    It 'väärään juureen päätyvä ketju hylätään ja kirjataan virhe; mitään ei tuoda' {
        $my = [pscustomobject]@{ Certificates = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection) }
        $my | Add-Member ScriptMethod Add { throw 'ei saa tuoda' }
        Mock Write-CertLog { }
        Mock Set-SslBinding { }
        Install-StagedCertificate -Cfg $script:cfg -Name web -Bindings @('web.example.test:443') -DvvRoot (New-TestCa -Name 'Väärä') -My $my -Ca $null
        Should -Invoke Write-CertLog -Times 1 -ParameterFilter { $Type -eq 'Error' -and $Message -like '*ketju ei päädy DVV*' }
        Should -Invoke Set-SslBinding -Times 0
    }
    It 'vajaa staging-tiedosto hylätään' {
        'vain-yksi-rivi' | Set-Content (Join-Path $script:staging 'vajaa.pfx.txt')
        Mock Write-CertLog { }
        $my = [pscustomobject]@{ Certificates = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection) }
        Install-StagedCertificate -Cfg $script:cfg -Name vajaa -Bindings @('x:443') -DvvRoot $script:chain.Root -My $my -Ca $null
        Should -Invoke Write-CertLog -ParameterFilter { $Type -eq 'Error' -and $Message -like '*vajaa*' }
    }
}
