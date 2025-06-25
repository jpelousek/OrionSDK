#
# IPAM_DhcpServerManagement.ps1
#
# This script demonstrates testing, creating and using DHCP server credentials, 
# adding DHCP servers to IPAM, and updating DHCP server configuration.
#
# IMPORTANT: All verbs except AddDhcpServer are supported since Observability Self-Hosted 2025.2.1

# Requires the SwisPowerShell module to be installed and imported
# Import-Module SwisPowerShell

# Connect to your SolarWinds instance. Always use specific user instead of certificate connection as IPAM verbs require user context.
$swis = Connect-Swis -Hostname "localhost" -UserName "admin" -Password "<REDACTED>"

enum DhcpServerType {
    Unknown = 0
    Windows = 1
    CISCO = 2
    ASA = 3
    ISC = 4
    Infoblox = 5
}

enum JobCompletionState {
    Unknown = 0
    Queued = 1
    Running = 2
    Canceling = 3
    Canceled = 4
    Failed = 5
    Finished = 6
    ChildStatus = 7
    ProcessingResult = 8
}

function Wait-ForJobResult([System.Guid]$jobId) {
    Write-Host "Waiting for job with ID $jobId to complete..."
    while ($true) {
        $job = Get-SwisData $swis "SELECT StatusText, CompletionState, IsSuccess FROM IPAM.UIJob WHERE WebId = @jobId" -Parameters @{"jobId" = $jobId }
        $completionState = [JobCompletionState]$job.CompletionState
        
        if ($completionState -eq [JobCompletionState]::Finished -or 
            $completionState -eq [JobCompletionState]::Failed -or 
            $completionState -eq [JobCompletionState]::Canceled) {
            break
        }
        
        Write-Host "Job status: $completionState"
        Start-Sleep -Seconds 2
    }
    
    if ($job.IsSuccess -eq $true) {
        Write-Host "Job completed successfully: $($job.StatusText)" -ForegroundColor Green
        return $true, $job.StatusText
    }
    else {
        Write-Host "Job failed: $($job.StatusText)" -ForegroundColor Red
        return $false, $job.StatusText
    }
}

#
# Define the target DHCP server node ID
#
$windowsNodeId = 4  # Replace with your Windows DHCP server Node ID
# For examples below, use the appropriate Node IDs for your environment
$ciscoNodeId = "<Enter ID>"     # Example ID for Cisco device
$asaNodeId = "<Enter ID>"      # Example ID for ASA device
$iscNodeId = "<Enter ID>"       # Example ID for ISC DHCP server
$infobloxNodeId = "<Enter ID>"  # Example ID for Infoblox server

#
# DHCP Server Credential Tests
#

# Test Windows DHCP server WMI credentials
Write-Host "Testing Windows DHCP server WMI credentials..." -ForegroundColor Cyan

$windowsTestCreds = @{
    "UserName" = "administrator";
    "Password" = "<REDACTED>";  # Replace with actual password
}

$uiJobId = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb StartDhcpCredentialsTest -Arguments @(
    $windowsNodeId, 
    [int][DhcpServerType]::Windows, 
    $null, # No credential ID since we're testing new credentials
    $windowsTestCreds
)

$success, $statusText = Wait-ForJobResult ([System.Guid]::Parse($uiJobId.'#text'))

if ($success) {
    Write-Host "Windows DHCP credential test passed! Creating credential..." -ForegroundColor Green
    
    # Create Windows DHCP credential
    $windowsCreds = @{
        "Name"     = "Windows_DHCP_Creds";
        "UserName" = $windowsTestCreds.UserName;
        "Password" = $windowsTestCreds.Password;
    }
    
    $credResult = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb CreateDhcpCredentials -Arguments @(
        [int][DhcpServerType]::Windows, 
        $windowsCreds
    )
    
    $credentialId = $credResult.'#text'
    Write-Host "Created Windows DHCP credential with ID: $credentialId" -ForegroundColor Green
    
    # Add DHCP Server using the created credential
    Write-Host "Adding Windows DHCP server to IPAM..." -ForegroundColor Cyan
    
    $result = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb AddDhcpServer -Arguments @(
        $windowsNodeId, # Node ID for the DHCP server
        "Windows DHCP", # Name for the new hierarchy group (or $null to use default)
        $null, # Name for the new credential if creating one
        $null, # Username for new credential
        $null, # Password for new credential
        $null, # Enable password for Cisco devices
        $null, # Protocol (0 for Telnet, 1 for SSH)
        $null, # Port for SSH/telnet
        $null, # Enable level for Cisco devices
        $credentialId, # ID of existing credential we created
        $null, # Cluster ID if server is part of a cluster
        60, # Interval to scan scopes in minutes
        30, # Server scan interval in minutes
        [int][DhcpServerType]::Windows, # Type of DHCP server
        $true, # Whether to automatically add new scopes
        $true             # Whether to enable subnet scanning
    )
    
    $dhcpServerId = Get-SwisData $swis "SELECT GroupId FROM IPAM.DhcpServer WHERE NodeId = @nodeId" -Parameters @{"nodeId" = $windowsNodeId }
    Write-Host "Added Windows DHCP Server with ID: $dhcpServerId" -ForegroundColor Green
    
    # Update DHCP server configuration
    Write-Host "Updating DHCP server configuration..." -ForegroundColor Cyan
    
    $propertiesToUpdate = @{
        "ScanInterval"           = 120; # Update scan interval to 120 minutes
        "NewSubnetsScanInterval" = 90; # Update new subnets scan interval to 90 minutes
        "AutoScanNewSubnets"     = $true; # Enable auto-scan for new subnets
        "AddNewScopes"           = $true; # Automatically add new scopes
    }
    
    $updateResult = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb UpdateDhcpServer -Arguments @(
        $dhcpServerId, 
        $propertiesToUpdate
    )
    
    Write-Host "DHCP server configuration updated: $($updateResult.'#text')" -ForegroundColor Green
    
    # Initiate a scan of the DHCP server
    Write-Host "Starting scan of the DHCP server..." -ForegroundColor Cyan
    
    $uiJobId = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb StartScanDhcpServer -Arguments @($dhcpServerId)
    $success, $scanStatusText = Wait-ForJobResult ([System.Guid]::Parse($uiJobId.'#text'))
    
    if ($success) {
        Write-Host "DHCP Server scan completed successfully!" -ForegroundColor Green
    }
    else {
        Write-Host "DHCP Server scan failed: $scanStatusText" -ForegroundColor Red
    }
}
else {
    Write-Host "Credential test failed: $statusText" -ForegroundColor Red
}

<#
# EXAMPLES FOR OTHER DHCP SERVER TYPES

# 1. Windows DHCP with Inherited Credentials
$uiJobId = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb StartDhcpCredentialsTest -Arguments @(
    $windowsNodeId, 
    [int][DhcpServerType]::Windows, 
    -1,  # Special value for inherited credentials
    $null
)
$success, $statusText = Wait-ForJobResult ([System.Guid]::Parse($uiJobId.'#text'))

# Windows DHCP with Inherited Credentials - Add Server
$result = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb AddDhcpServer -Arguments @(
    $windowsNodeId,   # Node ID for the DHCP server
    $null,            # Name for the new hierarchy group (or $null to use default)
    $null,            # Name for the new credential if creating one
    $null,            # Username for new credential
    $null,            # Password for new credential
    $null,            # Enable password for Cisco devices
    $null,            # Protocol (0 for Telnet, 1 for SSH)
    $null,            # Port for SSH/telnet
    $null,            # Enable level for Cisco devices
    -1,               # Inherited credentials ID
    $null,            # Cluster ID if server is part of a cluster
    60,               # Interval to scan scopes in minutes
    30,               # Server scan interval in minutes
    [int][DhcpServerType]::Windows,  # Type of DHCP server
    $true,            # Whether to automatically add new scopes
    $true             # Whether to enable subnet scanning
)

# 2. Cisco Router DHCP
$ciscoCreds = @{
    "Name" = "CiscoCreds";
    "UserName" = "admin";
    "Password" = "<Redacted>";
    "EnablePassword" = "<Redacted>";
    "EnableLevel" = "0";
    "ClientPort" = "22";
    "Protocol" = "1";  # 1 for SSH, 0 for Telnet
}

$credResult = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb CreateDhcpCredentials -Arguments @(
    [int][DhcpServerType]::CISCO, 
    $ciscoCreds
)
$ciscoCredId = $credResult.'#text'

# Cisco DHCP - Add Server
$result = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb AddDhcpServer -Arguments @(
    $ciscoNodeId,     # Node ID for the DHCP server
    "Cisco Routers",  # Name for the new hierarchy group (or $null to use default)
    $null,            # Name for the new credential if creating one
    $null,            # Username for new credential
    $null,            # Password for new credential
    $null,            # Enable password for Cisco devices
    $null,            # Protocol (0 for Telnet, 1 for SSH)
    $null,            # Port for SSH/telnet
    $null,            # Enable level for Cisco devices
    $ciscoCredId,     # ID of existing credential we created
    $null,            # Cluster ID if server is part of a cluster
    60,               # Interval to scan scopes in minutes
    30,               # Server scan interval in minutes
    [int][DhcpServerType]::CISCO,  # Type of DHCP server
    $true,            # Whether to automatically add new scopes
    $true             # Whether to enable subnet scanning
)

# 3. ASA DHCP
$asaCreds = @{
    "Name" = "ASACreds";
    "UserName" = "admin";
    "Password" = "<Redacted>";
    "EnablePassword" = "<Redacted>";
    "EnableLevel" = "0";
    "ClientPort" = "22";
    "Protocol" = "1";  # 1 for SSH, 0 for Telnet
}

$credResult = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb CreateDhcpCredentials -Arguments @(
    [int][DhcpServerType]::ASA, 
    $asaCreds
)
$asaCredId = $credResult.'#text'

# ASA DHCP - Add Server
$result = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb AddDhcpServer -Arguments @(
    $asaNodeId,       # Node ID for the DHCP server
    "ASA Firewalls",  # Name for the new hierarchy group (or $null to use default)
    $null,            # Name for the new credential if creating one
    $null,            # Username for new credential
    $null,            # Password for new credential
    $null,            # Enable password for Cisco devices
    $null,            # Protocol (0 for Telnet, 1 for SSH)
    $null,            # Port for SSH/telnet
    $null,            # Enable level for Cisco devices
    $asaCredId,       # ID of existing credential we created
    $null,            # Cluster ID if server is part of a cluster
    60,               # Interval to scan scopes in minutes
    30,               # Server scan interval in minutes
    [int][DhcpServerType]::ASA,  # Type of DHCP server
    $true,            # Whether to automatically add new scopes
    $true             # Whether to enable subnet scanning
)

# 4. ISC DHCP
$iscCreds = @{
    "Name" = "ISCcreds";
    "UserName" = "root";
    "Password" = "<Redacted>";
    "Protocol" = "1";  # 1 for SSH, 0 for Telnet
    "ClientPort" = "22"
}

$credResult = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb CreateDhcpCredentials -Arguments @(
    [int][DhcpServerType]::ISC, 
    $iscCreds
)
$iscCredId = $credResult.'#text'

# ISC DHCP - Add Server
$result = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb AddDhcpServer -Arguments @(
    $iscNodeId,            # Node ID for the DHCP server
    "ISC DHCP Servers",    # Name for the new hierarchy group (or $null to use default)
    $null,            # Name for the new credential if creating one
    $null,            # Username for new credential
    $null,            # Password for new credential
    $null,            # Enable password for Cisco devices
    $null,            # Protocol (0 for Telnet, 1 for SSH)
    $null,            # Port for SSH/telnet
    $null,            # Enable level for Cisco devices
    $iscCredId,            # ID of existing credential we created
    $null,                 # Cluster ID if server is part of a cluster
    60,                    # Interval to scan scopes in minutes
    30,                    # Server scan interval in minutes
    [int][DhcpServerType]::ISC,  # Type of DHCP server
    $true,                 # Whether to automatically add new scopes
    $true                  # Whether to enable subnet scanning
)

# 5. Infoblox DHCP
$infobloxCreds = @{
    "Name" = "InfobloxCreds";
    "UserName" = "admin";
    "Password" = "<Redacted>";
}

$credResult = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb CreateDhcpCredentials -Arguments @(
    [int][DhcpServerType]::Infoblox, 
    $infobloxCreds
)
$infobloxCredId = $credResult.'#text'

# Infoblox DHCP - Add Server
$result = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb AddDhcpServer -Arguments @(
    $infobloxNodeId,         # Node ID for the DHCP server
    "Infoblox Appliances",   # Name for the new hierarchy group (or $null to use default)
    $null,                   # Name for the new credential if creating one
    $null,                   # Username for new credential
    $null,                   # Password for new credential
    $null,                   # Enable password (not used for Infoblox)
    1,                       # Protocol (1 for API/HTTPS)
    443,                     # Port for API/HTTPS
    0,                       # Enable level (not used for Infoblox)
    $infobloxCredId,         # ID of existing credential we created
    $null,                   # Cluster ID if server is part of a cluster
    60,                      # Interval to scan scopes in minutes
    30,                      # Server scan interval in minutes
    [int][DhcpServerType]::Infoblox,  # Type of DHCP server
    $true,                   # Whether to automatically add new scopes
    $true                    # Whether to enable subnet scanning
)
#>

<#
# COMMON OPERATIONS EXAMPLES
# Scan all DHCP servers of a specific type
# Get all Windows DHCP servers
$windowsDhcpServers = Get-SwisData $swis "SELECT GroupId FROM IPAM.DhcpServer WHERE ServerType = @serverType" -Parameters @{"serverType" = [int][DhcpServerType]::Windows}

# Start a scan for each Windows DHCP server
foreach ($serverId in $windowsDhcpServers.GroupId) {
    Write-Host "Starting scan for Windows DHCP server ID: $serverId" -ForegroundColor Cyan
    $uiJobId = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb StartScanDhcpServer -Arguments @($serverId)
    Write-Host "Scan initiated with job ID: $($uiJobId.'#text')" -ForegroundColor Green
    
    # Optional: Wait for job completion
    # $success, $scanStatusText = Wait-ForJobResult ([System.Guid]::Parse($uiJobId.'#text'))
}

# Delete a DHCP server (uncomment to use)
<#
$serverIdToDelete = "151"  # Replace with the DHCP server ID you want to delete
$result = Invoke-SwisVerb $swis -EntityName IPAM.DhcpDnsManagement -Verb DeleteDhcpServer -Arguments @($serverIdToDelete)
Write-Host "Delete DHCP Server result: $($result.'#text')"
#>
#>
