[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$PublicDnsName,
    [string]$OobXmlFilePath
)

try {
    $ErrorActionPreference = "Stop"

    Start-Transcript -Path c:\cfn\log\$($MyInvocation.MyCommand.Name).txt -Append -IncludeInvocationHeader;

    $hostName = "localhost"
    $portNumber = 1611
    Write-Host "Creating Windows Relay Agent Rollout"
    Write-Host "Public IP of the EC2 instance is: "$hostName
    Write-Host "Port: "$portNumber

    Write-Host "Replacing _MASTERNAME_ in OOBXML.xml with Public IP of the EC2 instance"
    $content = Get-Content $OobXmlFilePath
    $data = $content.Replace("_MASTERNAME_", $PublicDnsName)
    #Set-Content C:\Windows\Temp\OOBXML.xml -value $content

    add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
                return true;
            }
    }
"@
# The closing here-string tag must not be indented

    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

    $base64AuthInfo = "YWRtaW46"

    $baseUri = "https://" + $hostName + ":" + $portNumber
    #C:\cfn\scripts\CheckIfBcmAgentIsInitialized.ps1 $baseUri $base64AuthInfo

    #$data = Get-Content C:\Windows\Temp\OOBXML.xml
    Write-Host "Importing OOB XML"
    $uri = $baseUri + "/raw/1/objects/import"
    Write-Host "Uri: "$uri

    Invoke-RestMethod -Method Put -Uri $uri -UseBasicParsing -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)} -Body $data
    Write-Host "OOB XML imported successfully"

    $base64AuthInfo = "YWRtaW46VHJhY2tpdHVzZXJAMDY="

    Write-Host "Assigning rollout server to Windows Relay Agent Rollout Configuration"
    $uri = $baseUri + "/api/1/rollout/server/1000/configuration/1007"
    Write-Host "Uri: "$uri

    $jsonResult = Invoke-RestMethod -Method Put -Uri $uri -UseBasicParsing -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)}
    Write-Host "Rollout server assigned successfully"
    Write-Host "Assignment Id: " $jsonResult.assignment.id

    Write-Host "Generating rollout package for Windows Relay Agent Rollout Configuration"
    $uri = $baseUri + "/api/1/rollout/server/assignment/" + $jsonResult.assignment.id + "/status"
    Write-Host "Uri: "$uri

    $data = @{
        status = "_STATUS_ASSIGNWAITING_"
    };

    $jsonBody = $data | ConvertTo-Json;
    Invoke-RestMethod -Method Put -Uri $uri -UseBasicParsing -Headers @{Authorization=("Basic {0}" -f $base64AuthInfo)} -Body $jsonBody
    Write-Host "Rollout package generated successfully"
}
catch {
    Write-Verbose "$($_.exception.message)@ $(Get-Date)"
    $_ | Write-AWSQuickStartException
}
