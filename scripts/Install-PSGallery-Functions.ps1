[CmdletBinding()]
param()

try {
    $ErrorActionPreference = 'Stop';

    Start-Transcript -Path c:\cfn\log\$($MyInvocation.MyCommand.Name).txt -Append -IncludeInvocationHeader;
    
    # As of April 2020, must use TLS 1.2 with PowerShell Gallery
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Setup PSGallery as a trusted repo and install PowerShellGet
    Install-PackageProvider -Name NuGet -Force
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    Install-Module PowerShellGet -Force

    # Install IniContent (PsIni) module
    Install-Module Psini -Force -AllowClobber
} catch {
    Write-Verbose "$($_.exception.message)@ $(Get-Date)"
    $_ | Write-AWSQuickStartException;
}