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

function Update-TrackIt-Admin-Password()
{
    $ac = New-Object -ComObject "MGC.Utils.Account"
    $work = New-Object -ComObject "NAMWork.NAMWorker"
    $dsn="Track-It"

    $retval = $ac.SetPassword($dsn, $TrackItAdminPassword)
    
    if($retval -eq $true)
    {
        Write-Host "Password changed"

        $encryptedPassword = $work.SetWorker($TrackItAdminPassword)

        $encryptedTrackItUserPwd = $work.SetWorker2($TrackItBcmAdminPassword)

        $encryptedPasswordSysAcc = $work.SetWorker("3,1," + $TrackItAdminPassword)

        $newEncryptedPassword = $ac.GetPassword($dsn, $false)

        $dbPrefix = $ac.GetPrefix($dsn, $true)

        $conStr = "DSN="+ $dsn +";Trusted_Connection=Yes"
        $connection = New-Object System.Data.Odbc.OdbcConnection
        $connection.ConnectionString = $conStr
        $connection.Open()

        Write-Host "Calling SQL script 1"
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "{call NAMSYSMANAGEWORK(?,?,?)}"
        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure

        $p1 = $cmd.CreateParameter()
        $p1.ParameterName = "@plainvar"
        $p1.Size = 512
        $p1.Value = $TrackItAdminPassword
        $cmd.Parameters.Add($p1)

        $p2 = $cmd.CreateParameter()
        $p2.ParameterName = "@encryptvar"
        $p2.Size = 512
        $p2.Value = $newEncryptedPassword
        $cmd.Parameters.Add($p2)

        $p3 = $cmd.CreateParameter()
        $p3.ParameterName = "@dbprefix"
        $p3.Size = 255
        $p3.Value = $dbPrefix
        $cmd.Parameters.Add($p3)

        $cmd.ExecuteNonQuery()
        $cmd.Dispose()

        Write-Host "Calling SQL script 2"
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "UPDATE [NAMSYSCSCONFIG] set WEBSTAFFPWD= ? where WEBSTAFFID= 'SELFSERVICE'" #N'" + $encryptedPassword + "'
        $p1 = $cmd.CreateParameter()
        $p1.Value = $encryptedPassword 
        $cmd.Parameters.Add($p1)
        $cmd.ExecuteNonQuery()
        $cmd.Dispose()

        Write-Host "Calling SQL script 3"
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "UPDATE [NAMSYSPROPERTIES] set [VALUE]= ? where [NAME]= 'namMBLCredentials'" #N'" + $encryptedPasswordSysAcc  + "'
        $p1 = $cmd.CreateParameter()
        $p1.Value = $encryptedPasswordSysAcc 
        $cmd.Parameters.Add($p1)
        $cmd.ExecuteNonQuery()
        $cmd.Dispose()

        Write-Host "Calling SQL script 4"
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "UPDATE [NAMSYSPROPERTIES] set [VALUE]= ? where [NAME]= 'bcmMasterSettings|Password'" #$encryptedTrackItUserPwd
        $p1 = $cmd.CreateParameter()
        $p1.Value = $encryptedTrackItUserPwd
        $cmd.Parameters.Add($p1)
        $cmd.ExecuteNonQuery()
        $cmd.Dispose()

        $connection.Close()

        return $true
    }
    else
    {
        Write-Host "Could not change password"

        return $false
    }
}

function Install-TrackIt-License()
{
    $licFile='C:\cfn\scripts\license.licx'

    $licObj = New-Object -ComObject 'NAMLicenseCount.License'

    $licObj.ReadLicenseFile($licFile)
    Write-Host 'License file read successfully'

    $licObj.InstallLicenseToDSN('Track-It', '_SMSYSADMIN_', $TrackItAdminPassword, '', 'trackit', [string]$TrackItInstanceDomainComputerName)
    Write-Host 'License installed to database'
}

try {
    $ErrorActionPreference = 'Stop';
    
    Start-Transcript -Path c:\cfn\log\UpdateLicense.txt -Append -IncludeInvocationHeader;

    if(Update-TrackIt-Admin-Password -eq $true)
    {
        Install-TrackIt-License
    }

} catch {
    Write-Verbose "$($_.exception.message)@ $(Get-Date)"
    $_ | Write-Host;
}


