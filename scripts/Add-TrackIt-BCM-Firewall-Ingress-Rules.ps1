[CmdletBinding()]
param()

try {
    $ErrorActionPreference = 'Stop';

    Start-Transcript -Path c:\cfn\log\$($MyInvocation.MyCommand.Name).txt -Append -IncludeInvocationHeader;

    New-NetFirewallRule -DisplayName 'Track-It! Web (External User) Ingress Rule (tcp/80)' -Direction Inbound -Action Allow -LocalPort 80 -Protocol TCP;
    New-NetFirewallRule -DisplayName 'BCM Client Agent Ingress Rule (tcp/1610)' -Direction Inbound -Action Allow -LocalPort 1610 -Protocol TCP;
    New-NetFirewallRule -DisplayName 'BCM Web Console Ingress Rule (tcp/1611)' -Direction Inbound -Action Allow -LocalPort 1611 -Protocol TCP;
    New-NetFirewallRule -DisplayName 'BCM WebAPI Ingress Rule (tcp/1616)' -Direction Inbound -Action Allow -LocalPort 1616 -Protocol TCP;
} catch {
    Write-Verbose "$($_.exception.message)@ $(Get-Date)"
    $_ | Write-AWSQuickStartException;
}