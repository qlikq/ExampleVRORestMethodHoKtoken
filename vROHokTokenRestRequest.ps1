<#
In order to test it, you need to get vsphere SDK for webservices, as this is using the libraries from it.
new-webserviceproxy can't handle soap security headers. You also need PKCS#12 pfx certificate (in my example)
#>

#https://www.dorkbrain.com/docs/2017/09/02/gzip-in-powershell/
Function ConvertTo-GZipString () {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True, ValueFromPipelinebyPropertyName = $True)]
        $String
    )
    Process {
        $String | ForEach-Object {
            $stream = [System.IO.MemoryStream]::new()
            $writer = [System.IO.StreamWriter][System.IO.Compression.GZipStream]::new($stream, [System.IO.Compression.CompressionMode]::Compress)
            $writer.Write($_)
            $writer.Close()
            [Convert]::ToBase64String([byte[]][char[]]$stream.ToArray())
        }
    }
}
Add-Type -Path 'd:\vsphereWebServicesSDK67\ssoclient\dotnet\cs\samples\VMware.Binding.WsTrust\bin\Debug\VMware.Binding.WsTrust.dll'
Add-Type -Path 'd:\vsphereWebServicesSDK67\ssoclient\dotnet\cs\samples\VMware.Binding.WsTrust\bin\Debug\STSService.dll'

$certificatetobeadded = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
#i have generated my certificate with 'greg3' password
$certificatetobeadded.Import('d:\vro\greg\greg3.pfx', 'greg3', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet)

#[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls12;
#[VMware.Binding.WsTrust.SamlTokenHelper]::SetupServerCertificateValidation()

$signingCertificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
$signingCertificate.Import('d:\vro\greg\greg3.pfx', 'greg3', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet)
$service = [VMware.Binding.WsTrust.SamlTokenHelper]::GetSTSService('https://vc001.greg.labs:7444/sts/STSService', 'administrator@vsphere.local', 'VMware1!', $signingCertificate)
$token = [VMware.Binding.WsTrust.SamlTokenHelper]::GetHokRequestSecurityTokenType()
$token.SignatureAlgorithm = [vmware.sso.SignatureAlgorithmEnum]::httpwwww3org200104xmldsigmorersasha256
$response = $service.Issue($token)

$responsetoken = $response.RequestSecurityTokenResponse.RequestedSecurityToken
$responsetokenXML = $responsetoken.OuterXml
$encodedANDgzippedtoken = ConvertTo-GZipString -String $responsetokenXML

$nl = (0x0A -as [char])
$restmethod = 'GET'
$timestamp = [DateTimeOffset]::Now.ToUnixTimeSeconds().ToString()
$nonce = $timestamp + ':ass234'
[system.uri]$uri = 'https://vro816.greg.labs:443/vco/api/org/{id}/workflows?maxResult=3&queryCount=false'
$httprequesturi = '/' + $uri.AbsolutePath.split('/')[-1] + $uri.Query
$httprequesthost = $uri.Host
$httprequestport = $uri.Port
$noext = ''

$normalizedrequeststring = $timestamp + "`n" + $nonce + "`n" + $timestamp + "`n" + $restmethod + "`n" + $httprequesturi + "`n" + $httprequesthost + "`n" + $httprequestport + "`n" + $noext + "`n"



$popt = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable   
$psigningCertificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
$psigningCertificate.Import('d:\vro\greg\greg3.pfx', 'greg3', $popt)
#converted from c# to PS from https://stackoverflow.com/questions/7444586/how-can-i-sign-a-file-using-rsa-and-sha256-with-net

$privatekey = $psigningCertificate.PrivateKey

$privatekey1 = New-Object System.Security.Cryptography.RSACryptoServiceProvider  
$privatekey1.ImportParameters($privatekey.ExportParameters($true))
$enc = [system.Text.Encoding]::UTF8
$data = $enc.GetBytes($normalizedrequeststring) 
$sig = $privatekey1.SignData($data, "SHA256")
$base64sig = [Convert]::ToBase64String($sig)
#[bool]$isValid = $privateKey1.VerifyData($data, "SHA256", $sig)


$headervalue = 'SIGN token="{0}",nonce="{1}",signature_alg="RSA-SHA256",signature="{2}"' -f $encodedANDgzippedtoken, $nonce, $base64sig
$header = @{'Authorization' = $headervalue }
$answer = Invoke-WebRequest -Uri 'https://vro816.greg.labs:443/vco/api/org/{id}/workflows?maxResult=3&queryCount=false' -Headers $header
$answer.Content|convertfrom-json

<#TODO
Write it natively so that there is no need to load dlls from sdk.
#>

<#
Please find the details below shared by the engineering team.

The Authorization header has the following.

Authorization: SIGN token="...",
               nonce="1589541389518:1761545587",
               bodyhash="k9kbtCIy0CkI3/FEfpS/oIDjk6k=",
               signature_alg="RSA-SHA256",
               signature="..."


Description:
-------
token              REQUIRED. The SAML2 token identifying the caller. The value is calculated as BASE64(GZIP(SAML2)).

nonce              REQUIRED. A unique string generated by the client allowing the server to identify replay attacks and reject such requests. 
                             The strings must be unique across all requests of a single client. The definition is as specified in Section 3.1
                             of draft-ietf-oauth-v2-http-mac (http://tools.ietf.org/id/draft-ietf-oauth-v2-http-mac-00.txt) with one difference - the first component should be the current time expressed in
                             the number of milliseconds since January 1, 1970 00:00:00 GMT with no leading zeros.

bodyhash           OPTIONAL. A hash value computed as described in Section 3.2 of draft-ietf-oauth-v2-http-mac (http://tools.ietf.org/id/draft-ietf-oauth-v2-http-mac-00.txt) over the entire HTTP request 
                             entity body (as defined in Section 7.2 of RFC 2616(http://www.ietf.org/rfc/rfc2616.txt)). Note that the body hash may be missing only if there is no
                             request body, i.e. empty body. Otherwise it is required.

signature_alg      REQUIRED. The signature algorithm used by the client to sign the request - "RSA-SHA256", "RSA-SHA384" and "RSA-SHA512"

signature          REQUIRED. A message signature calculated over the normalized request as 
                             BASE64(signature-algorithm(private key, request)). The request normalization is done 
                             as defined in Section 3.3.1 of draft-ietf-oauth-v2-http-mac (http://tools.ietf.org/id/draft-ietf-oauth-v2-http-mac-00.txt) with two exception - (a) the body hash is included without 
                             BASE64 applied and (b) no "ext" field is appended. All text based fields in the normalized request
                             are encoded in UTF-8.
#>