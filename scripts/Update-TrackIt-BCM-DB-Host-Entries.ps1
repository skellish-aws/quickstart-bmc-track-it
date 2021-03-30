[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TrackItInstanceDomainComputerName
)

try {
    $ErrorActionPreference = 'Stop';
    
    Start-Transcript -Path c:\cfn\log\$($MyInvocation.MyCommand.Name).txt -Append -IncludeInvocationHeader;

    # Update TrackIt! and BCM ODBC DSNs to use this instances current name (e.g., TrackIt01)
    Set-OdbcDsn -Name BcmDb -DsnType System -Platform 64-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;
    Set-OdbcDsn -Name SelfService -DsnType System -Platform 32-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;
    Set-OdbcDsn -Name Track-It -DsnType System -Platform 32-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;
    Set-OdbcDsn -Name TrackItBR -DsnType System -Platform 32-bit -SetPropertyValue Server=$TrackItInstanceDomainComputerName;

    # Read in Vision64Database.ini (Assumes PsIni module from PSGallery is already installed)
    $vision64DatabaseIniPath = 'C:\Program Files\BMC Software\Client Management\Master\config\Vision64Database.ini';
    $ini = Get-IniContent $vision64DatabaseIniPath;

    # Modify DB/Host and write back
    $ini.Database.DatabaseType = 'ODBC';
    $ini.Database.DatabaseName = 'BcmDb';
    $ini.Database.Host = "$TrackItInstanceDomainComputerName";
    Out-IniFile -InputObject $ini -FilePath $vision64DatabaseIniPath -Force -Pretty -Loose;

} catch {
    Write-Verbose "$($_.exception.message)@ $(Get-Date)"
    $_ | Write-AWSQuickStartException;
}
