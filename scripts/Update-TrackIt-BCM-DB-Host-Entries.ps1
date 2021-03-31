[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TrackItInstanceDomainComputerName,
    [Parameter(Mandatory=$true)]
    [string]$PublicDnsName
)

try {
    $ErrorActionPreference = 'Stop';
    
    Start-Transcript -Path c:\cfn\log\$($MyInvocation.MyCommand.Name).txt -Append -IncludeInvocationHeader;


    Write-Host "Stopping services"
    $services = @("TrackIt Job Processor - TrackItBR", "TrackIt Mail Processor - TrackItBR", "TrackItInfrastructureService", "W3SVC")
    Stop-Service -Name $services -Force

    Write-Host "Updating DSN's"
    # Update TrackIt! and BCM ODBC DSNs to use this instances current name (e.g., TrackIt01)
    Set-OdbcDsn -Name BcmDb -DsnType System -Platform 64-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;
    Set-OdbcDsn -Name SelfService -DsnType System -Platform 32-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;
    Set-OdbcDsn -Name Track-It -DsnType System -Platform 32-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;
    Set-OdbcDsn -Name TrackItBR -DsnType System -Platform 32-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;

    # Read in Vision64Database.ini (Assumes PsIni module from PSGallery is already installed)
    $vision64DatabaseIniPath = 'C:\Program Files\BMC Software\Client Management\Master\config\Vision64Database.ini';
    $mtxagentIniPath = 'C:\Program Files\BMC Software\Client Management\Master\config\mtxagent.ini';
    $ini = Get-IniContent $vision64DatabaseIniPath;

    # Modify DB/Host and write back
    Write-Host "Updating BCM vision64database.ini"
    $ini.Database.DatabaseType = 'ODBC';
    $ini.Database.DatabaseName = 'BcmDb';
    $ini.Database.Host = "$TrackItInstanceDomainComputerName";
    $ini.Console.PublicJNLPAddress = "$PublicDnsName`:1610"
    Out-IniFile -InputObject $ini -FilePath $vision64DatabaseIniPath -Force -Pretty -Loose;

    Write-Host "Updating BCM mtxagent.ini"
    $ini = Get-IniContent $mtxagentIniPath;
    $ini.Security.CertDNSNames="$PublicDnsName,$TrackItInstanceDomainComputerName"
    #TODO: $ini.Security.CertIpAddresses="$PublicIpAddress,$PrivateIpAddress"
    Out-IniFile -InputObject $ini -FilePath $mtxagentIniPath -Force -Pretty -Loose;

    Write-Host "Updating web.config"
    $webConfigPath = "C:\Program Files (x86)\BMC\Track-It!\Application Server\Web.config"
    $xml = [xml](Get-Content $webConfigPath)

    $values = @{
        UseRelayForDiscoveryAndRollout = 'true'
    }

    foreach($key in $values.Keys)
    {
        # Use XPath to find the appropriate node
        if(($addKey = $xml.SelectSingleNode("/configuration/appSettings/add[@key = '$key']")))
        {
            Write-Host "Found key: '$key' in XML, updating value to $($values[$key])"
            $addKey.SetAttribute('value',$values[$key])
        }
        else
        {
            Write-Host "Key not found. Adding new appSettings element"
            $appSettings = $xml.SelectSingleNode("/configuration/appSettings")
            $node = $xml.CreateElement("add")
            $node.SetAttribute("key", $key)
            $node.SetAttribute("value",$values[$key])
            $appSettings.AppendChild($node)
        }
    }

    $xml.Save($webConfigPath)

    Write-Host "Replacing files"
    Expand-Archive -Path "C:\cfn\scripts\FilesToReplace.zip" -DestinationPath "C:\Program Files (x86)\BMC\Track-It!" -Force


    Write-Host "Updating license"
    $job = Start-Job -FilePath "C:\cfn\scripts\UpdateLicense.ps1" -InputObject $TrackItInstanceDomainComputerName -RunAs32

    Wait-Job  $job > $null
    Receive-Job  $job

    Remove-Item "C:\cfn\scripts\UpdateLicense.ps1" -Force
    
    Write-Host "Updating COM+ package password"

    $objShell = New-Object -ComObject "WScript.Shell"
    $szUser = "$TrackItInstanceDomainComputerName\TIComPlusUser"

    $szPassword = ""
    if($env:ADMIN_PASSWORD -ne "")
    {
        $szPassword = $env:ADMIN_PASSWORD
    }

    $catalog = New-Object -ComObject "COMAdmin.COMAdminCatalog"
    $applications = $catalog.GetCollection("Applications")
    $applications.Populate()
    [int]$i = 0
    while($i -lt [int]$applications.Count)
    {
        $COMApp = $applications.Item($i)
        if($COMApp.Name -eq "Track-It! Server Components")
        {
            Write-Host "Updating password for Track-It! Server Components"
            $COMApp.Value("Identity") = $szUser
            $COMApp.Value("Password") = $szPassword
            $applications.SaveChanges()
            break
        }
        $i = $i + 1
    }
    [Environment]::SetEnvironmentVariable("ADMIN_PASSWORD", $null, [System.EnvironmentVariableTarget]::Machine)

    Write-Host "Starting services"
    Start-Service -Name $services

    Write-Host "Registering Export compliance app"
    $expPath = "C:\Program Files (x86)\BMC\Track-It!\ExportCheckApp"
    Start-Process -Wait -FilePath "$expPath\ExportLicenseAgreement.WebHost.exe" -WorkingDirectory "$expPath" -ArgumentList register_iis_app

} catch {
    Write-Verbose "$($_.exception.message)@ $(Get-Date)"
    $_ | Write-AWSQuickStartException;
}
