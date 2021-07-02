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

function GetConnectionString{
    
    param(
        [string] $dsn, 
        [string] $user, 
        [string] $password
    )

    $connectionStringbuilder = New-Object System.Data.Odbc.OdbcConnectionStringBuilder
    $connectionStringbuilder.Add("DSN",$dsn)
    $connectionStringbuilder.Add("UID",$user)
    $connectionStringbuilder.Add("PWD",$password)

    return $connectionStringbuilder.ConnectionString;
}

function GetConnection{
    $conn = New-Object System.Data.Odbc.OdbcConnection
    

    return $conn
}

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

        $encryptedPasswordSysAcc = $work.SetWorker("3,1," + $TrackItAdminPassword)

        $newEncryptedPassword = $ac.GetPassword($dsn, $false)

        $dbPrefix = $ac.GetPrefix($dsn, $true)

        $conStr = "DSN="+ $dsn +";Trusted_Connection=Yes"
        $connection = New-Object System.Data.Odbc.OdbcConnection
        $connection.ConnectionString = $conStr
        $connection.Open()

        Write-Host "Calling SQL script 1"
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "{call NAMSYSMANAGEWORK(N'" + $TrackItAdminPassword + "',N'" + $newEncryptedPassword + "',N'" + $dbPrefix + "')}"
        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure

        $cmd.ExecuteNonQuery()
        $cmd.Dispose()

        Write-Host "Calling SQL script 2"
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "UPDATE [NAMSYSCSCONFIG] set WEBSTAFFPWD= N'" + $encryptedPassword + "' where WEBSTAFFID= 'SELFSERVICE'"
        $cmd.ExecuteNonQuery()
        $cmd.Dispose()

        Write-Host "Calling SQL script 3"
        $cmd = $connection.CreateCommand()
        $cmd.CommandText = "UPDATE [NAMSYSPROPERTIES] set [VALUE]= N'" + $encryptedPasswordSysAcc + "' where [NAME]= 'namMBLCredentials'"
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


