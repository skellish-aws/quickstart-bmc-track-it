try {
    $ErrorActionPreference = 'Stop';
    
    Start-Transcript -Path c:\cfn\log\UpdateLicense.txt -Append -IncludeInvocationHeader;

    $licFile='C:\cfn\scripts\license.licx'

    $licObj = New-Object -ComObject 'NAMLicenseCount.License'

    $licObj.ReadLicenseFile($licFile)
    Write-Host 'License file read successfully'
    $passwd=[string]([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("Ym1jQWRtMW4h")))
    #Write-Host "Password: $passwd"
    $licObj.InstallLicenseToDSN('Track-It', '_SMSYSADMIN_', $passwd, '', 'trackit', [string]$input)
    Write-Host 'License installed to database'

} catch {
    Write-Verbose "$($_.exception.message)@ $(Get-Date)"
    $_ | Write-Host;
}


