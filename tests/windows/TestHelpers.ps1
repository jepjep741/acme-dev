# Pester-testien apufunktiot: testivarmenteet (.NET CertificateRequest) ja paikallinen TLS-palvelin.
# Vain testit (pwsh 7 / .NET); tuotantoskriptit ovat PS 5.1 -yhteensopivia.

$X = 'System.Security.Cryptography.X509Certificates'

function New-TestCa {
    param([string]$Name, $Issuer = $null, [int]$Days = 365, [switch]$Expired)
    $key = [System.Security.Cryptography.RSA]::Create(2048)
    $req = New-Object "$X.CertificateRequest" "CN=$Name", $key, 'SHA256', ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $req.CertificateExtensions.Add((New-Object "$X.X509BasicConstraintsExtension" $true, $false, 0, $true))
    $req.CertificateExtensions.Add((New-Object "$X.X509KeyUsageExtension" ([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]'KeyCertSign,CrlSign'), $true))
    $req.CertificateExtensions.Add((New-Object "$X.X509SubjectKeyIdentifierExtension" $req.PublicKey, $false))
    $nb = [DateTimeOffset]::UtcNow.AddDays(-1); $na = $nb.AddDays($Days)
    if ($Issuer) {
        $serial = [byte[]](@(Get-Random -Minimum 1 -Maximum 128) + (2..16 | ForEach-Object { Get-Random -Maximum 256 }))
        $c = $req.Create($Issuer, $nb, $na, $serial)
        return [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($c, $key)
    }
    $req.CreateSelfSigned($nb, $na)
}

function New-TestLeaf {
    param([string]$DnsName, $Issuer, [int]$Days = 90, [switch]$Expired)
    $key = [System.Security.Cryptography.RSA]::Create(2048)
    $req = New-Object "$X.CertificateRequest" "CN=$DnsName", $key, 'SHA256', ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $san = New-Object "$X.SubjectAlternativeNameBuilder"; $san.AddDnsName($DnsName)
    $req.CertificateExtensions.Add($san.Build())
    $eku = New-Object System.Security.Cryptography.OidCollection; [void]$eku.Add((New-Object System.Security.Cryptography.Oid '1.3.6.1.5.5.7.3.1'))
    $req.CertificateExtensions.Add((New-Object "$X.X509EnhancedKeyUsageExtension" $eku, $false))
    if ($Expired) { $nb = [DateTimeOffset]::UtcNow.AddHours(-20); $na = [DateTimeOffset]::UtcNow.AddHours(-1) }
    else { $nb = [DateTimeOffset]::UtcNow.AddMinutes(-5); $na = $nb.AddDays($Days) }
    $serial = [byte[]](@(Get-Random -Minimum 1 -Maximum 128) + (2..16 | ForEach-Object { Get-Random -Maximum 256 }))
    $c = $req.Create($Issuer, $nb, $na, $serial)
    [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($c, $key)
}

function ConvertTo-Pem {
    param($Cert)
    "-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($Cert.RawData, 'InsertLineBreaks') + "`n-----END CERTIFICATE-----`n"
}

# Testiketju: DVV-juuri -> välivarmenne -> palvelinvarmenne
function New-TestChain {
    param([string]$DnsName = 'web.example.test', [switch]$Expired)
    $root = New-TestCa -Name 'Test DVV Root'
    $int = New-TestCa -Name 'Test DVV Issuing' -Issuer $root -Days 300
    $leaf = New-TestLeaf -DnsName $DnsName -Issuer $int -Expired:$Expired
    [pscustomobject]@{ Root = $root; Intermediate = $int; Leaf = $leaf }
}

# Paikallinen TLS-palvelin taustasäikeessä; vastaa yhteen HTTP-pyyntöön Date-otsakkeella.
function Start-TestTlsServer {
    param($Certificate, [int]$StatusCode = 200, [datetime]$Date = (Get-Date).ToUniversalTime())
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $job = Start-ThreadJob -ArgumentList $listener, $Certificate, $StatusCode, $Date -ScriptBlock {
        param($l, $cert, $code, $date)
        try {
            $client = $l.AcceptTcpClient()
            $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
            $ssl.AuthenticateAsServer($cert)
            $reader = [System.IO.StreamReader]::new($ssl)
            while ($reader.ReadLine()) { }
            $resp = "HTTP/1.1 $code X`r`nDate: $($date.ToString('r'))`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $b = [System.Text.Encoding]::ASCII.GetBytes($resp); $ssl.Write($b, 0, $b.Length); $ssl.Flush()
            $client.Close()
        }
        catch { } finally { $l.Stop() }
    }
    [pscustomobject]@{ Port = $port; Job = $job; Listener = $listener }
}

function Stop-TestTlsServer {
    param($Server)
    try { $Server.Listener.Stop() } catch { }
    $Server.Job | Wait-Job -Timeout 5 | Out-Null
    $Server.Job | Remove-Job -Force -ErrorAction SilentlyContinue
}
