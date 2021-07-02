[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TrackItInstanceDomainComputerName,

    [Parameter(Mandatory=$true)]
    [string]$PublicDnsName,

    [Parameter(Mandatory=$true)]
    [string]$TrackItAdminPassword,

    [Parameter(Mandatory=$true)]
    [string]$TrackItBcmAdminPassword
)

$services = @("TrackIt Job Processor - TrackItBR", "TrackIt Mail Processor - TrackItBR", "TrackItInfrastructureService", "W3SVC")

function Stop-Services{

    Write-Host "Stopping services"
    Stop-Service -Name ($services + @("BMC Client Management")) -Force

}

function Update-DSNs{

    Write-Host "Updating DSN's"
    # Update TrackIt! and BCM ODBC DSNs to use this instances current name (e.g., TrackIt01)
    Set-OdbcDsn -Name BcmDb -DsnType System -Platform 64-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;
    Set-OdbcDsn -Name SelfService -DsnType System -Platform 32-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;
    Set-OdbcDsn -Name Track-It -DsnType System -Platform 32-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;
    Set-OdbcDsn -Name TrackItBR -DsnType System -Platform 32-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;

}

function Update-BcmConfiguration{

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

}

function Update-TrackItWebConfig{

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

}

function Replace-TrackItBinaries{

    Write-Host "Replacing Track-It! binaries"
    Expand-Archive -Path "C:\cfn\scripts\FilesToReplace.zip" -DestinationPath "C:\Program Files (x86)\BMC\Track-It!" -Force

}

function Update-ApplicationLicenses{

    Write-Host "Updating license"
    $job = Start-Job -FilePath "C:\cfn\scripts\UpdateLicense.ps1" -RunAs32 -ArgumentList "$TrackItInstanceDomainComputerName", "$PublicDnsName", "$TrackItAdminPassword", "$TrackItBcmAdminPassword"

    Wait-Job  $job > $null
    Receive-Job  $job

    Remove-Item "C:\cfn\scripts\UpdateLicense.ps1" -Force
    
}

function Update-BcmMasterName{

    $sql="UPDATE dbo.NAMSYSPROPERTIES SET VALUE = '$PublicDnsName' where NAME = 'bcmMasterSettings|Server'"
    Invoke-SqlCmd -ServerInstance $TrackItInstanceDomainComputerName -Database "trackit" -Query $sql

}

# Because Track-It! COM+ applications are pre-installed when EC2 AMI is created, their Windows Identity,
# is EC2AMZ_xxxxxx\TIComPlusUser where xxxxxx is from the source machine which means the identify does not
# exist on the deployed machine. We need to replace the COM+ application Identity with the deployed 
# machines identity (EC2AMZ_yyyyyy\TIComPlusUser), but to do that we need the user's password which we 
# also don't have from the source machine. 
#
# To overcome we:
# 1. Change the TIComPlusUser password to the passed in Track-It! Admin password
# 2. Then use that to update the identity for the COM+ apps
#
function Update-ComPlusCredentials{

    Write-Host "Updating COM+ package password"

    $objShell = New-Object -ComObject "WScript.Shell"
    $szUser = "TIComPlusUser"

    # Update the TIComPlusUser password
    Get-LocalUser -Name $szUser | Set-LocalUser -Password (ConvertTo-SecureString -String $TrackItAdminPassword -AsPlainText -Force) 

#    $szPassword = ""
#    if($env:ADMIN_PASSWORD -ne "")
#    {
#        $szPassword = $env:ADMIN_PASSWORD
#    }

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
            $COMApp.Value("Password") = $TrackItAdminPassword
            $applications.SaveChanges()
            break
        }
        $i = $i + 1
    }
    [Environment]::SetEnvironmentVariable("ADMIN_PASSWORD", $null, [System.EnvironmentVariableTarget]::Machine)
}

function Start-Services{

    Write-Host "Starting services"
    Start-Service -Name ($services + @("BMC Client Management"))

    Write-Host "Setting services to auto-start"
    foreach($s in ($services + @("BMC Client Management"))) { Set-Service $s -StartupType Automatic }
}

function Register-ExportComplianceApp{

    Write-Host "Registering Export compliance app"
    $expPath = "C:\Program Files (x86)\BMC\Track-It!\ExportCheckApp"
    Start-Process -Wait -FilePath "$expPath\ExportLicenseAgreement.WebHost.exe" -WorkingDirectory "$expPath" -ArgumentList register_iis_app
}

try {

    $ErrorActionPreference = 'Stop';
    
    Start-Transcript -Path c:\cfn\log\$($MyInvocation.MyCommand.Name).txt -Append -IncludeInvocationHeader;

    Stop-Services

    Update-DSNs

    Update-BcmConfiguration

    Update-TrackItWebConfig

    Replace-TrackItBinaries

    Update-ApplicationLicenses
    
    Update-BcmMasterName

    Update-ComPlusCredentials

    Start-Services

    Register-ExportComplianceApp

} catch {
    Write-Verbose "$($_.exception.message)@ $(Get-Date)"
    $_ | Write-AWSQuickStartException;
}
