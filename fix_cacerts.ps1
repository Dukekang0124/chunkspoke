$keystore = "D:\android-build-tools\jdk\lib\security\cacerts"
$keytool = "D:\android-build-tools\jdk\bin\keytool.exe"
$storepass = "changeit"
$tmp = "$env:TEMP\certs_export"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$i = 0
foreach ($store in @('LocalMachine\Root', 'CurrentUser\Root')) {
    foreach ($cert in (Get-ChildItem "Cert:\$store" -ErrorAction SilentlyContinue)) {
        $i++
        $p = "$tmp\c$i.der"
        try {
            $bytes = $cert.Export('Cert')
            [System.IO.File]::WriteAllBytes($p, $bytes)
            & $keytool -importcert -noprompt -keystore $keystore -storepass $storepass -alias "winca$i" -file $p 2>$null
        } catch { }
    }
}
Write-Host "IMPORTED_TOTAL=$i"
