<#
.SYNOPSIS
Create a Proxmox QEMU VM named AC-SVR1 (configurable) and attach a Windows ISO.

.DESCRIPTION
This script uses the Proxmox REST API to create a new VM with sane defaults suitable for
hosting a small Windows Nano Server for the OsmUserWeb application. It requires either an
API token (recommended) or username/password credentials.

NOTES
- This script only provisions the VM and boots the ISO. It does not perform in-guest OS
  installation or post-install configuration.
- Update the parameters to match your Proxmox environment (node name, storages, ISO name).

.EXAMPLE
.
PS> .\Create-Proxmox-AC-SVR1.ps1 -ProxmoxHost "proxmox.example.local" -Node "pve-node1" -VmId 601 -VmName "AC-SVR1" -IsoStorage "local" -IsoFile "WindowsNano.iso" -DiskStorage "local-lvm" -ApiTokenId "apiuser!tokenid" -ApiTokenSecret (Read-Host -AsSecureString 'token')
#>
param(
    [Parameter(Mandatory=$true)] [string]$ProxmoxHost,
    [Parameter(Mandatory=$true)] [string]$Node,
    [Parameter(Mandatory=$true)] [int]$VmId,
    [Parameter(Mandatory=$true)] [string]$VmName,

    [Parameter(Mandatory=$true)] [string]$IsoStorage,
    [Parameter(Mandatory=$true)] [string]$IsoFile,
    [Parameter(Mandatory=$true)] [string]$DiskStorage,

    # Either supply an API token (recommended) or username & password
    [string]$ApiTokenId,
    [System.Security.SecureString]$ApiTokenSecret,

    [string]$Username,
    [System.Security.SecureString]$Password,

    # Optional tuning
    [int]$Cores = 2,
    [int]$MemoryMB = 2048,
    [int]$DiskGB = 32,
    [string]$Bridge = 'vmbr0'
)

function ConvertFrom-SecureStringToPlain([System.Security.SecureString]$s) {
    if (-not $s) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if (-not $ApiTokenId -and -not $Username) {
    Write-Error "Provide either -ApiTokenId (preferred) or -Username to authenticate to Proxmox."
    exit 2
}

$baseUrl = "https://$ProxmoxHost:8006/api2/json"

# Build authentication headers
$headers = @{}
if ($ApiTokenId) {
    $tokenPlain = ConvertFrom-SecureStringToPlain -s $ApiTokenSecret
    if (-not $tokenPlain) {
        Write-Host "Please enter the API token secret:" -NoNewline
        $tokenPlain = Read-Host -AsSecureString "API token" | ConvertFrom-SecureStringToPlain
    }
    $headers['Authorization'] = "PVEAPIToken=$ApiTokenId=$tokenPlain"
} else {
    $pw = ConvertFrom-SecureStringToPlain -s $Password
    $body = @{ username = $Username; password = $pw }
    $resp = Invoke-RestMethod -Method Post -Uri "$baseUrl/access/ticket" -Body $body -SkipCertificateCheck -ErrorAction Stop
    $ticket = $resp.data.ticket
    $csrf = $resp.data.CSRFPreventionToken
    $headers['Cookie'] = "PVEAuthCookie=$ticket"
    $headers['CSRFPreventionToken'] = $csrf
}

# Helper: check if VM id exists
try {
    $check = Invoke-RestMethod -Method Get -Uri "$baseUrl/nodes/$Node/qemu/$VmId/status/current" -Headers $headers -SkipCertificateCheck -ErrorAction Stop
    Write-Error "A VM with ID $VmId already exists on node $Node. Aborting."
    exit 3
} catch {
    # Expected: 404 if not found
}

# Create VM
$createParams = @{
    vmid       = $VmId
    name       = $VmName
    cores      = $Cores
    memory     = $MemoryMB
    net0       = "virtio,bridge=$Bridge"
    ide2       = "$IsoStorage:iso/$IsoFile,media=cdrom"
    sata0      = "$DiskStorage:${VmId}-disk0,size=${DiskGB}G"
    scsihw     = 'virtio-scsi-pci'
    ostype     = 'win10'
    scsi0      = "$DiskStorage:${VmId}-disk0,size=${DiskGB}G"
    boot       = 'cdn'
    agent      = 1
}

# Convert to form data
$form = $createParams.GetEnumerator() | ForEach-Object { "{0}={1}" -f ([uri]::EscapeDataString($_.Key)), ([uri]::EscapeDataString($_.Value.ToString())) } -join '&'

try {
    $resp = Invoke-RestMethod -Method Post -Uri "$baseUrl/nodes/$Node/qemu" -Body $form -Headers $headers -ContentType 'application/x-www-form-urlencoded' -SkipCertificateCheck -ErrorAction Stop
    Write-Host "Create VM task: $($resp.data)"
} catch {
    Write-Error "VM creation failed: $($_.Exception.Message)"
    exit 4
}

# Start VM
try {
    $start = Invoke-RestMethod -Method Post -Uri "$baseUrl/nodes/$Node/qemu/$VmId/status/start" -Headers $headers -SkipCertificateCheck -ErrorAction Stop
    Write-Host "Start VM task: $($start.data)"
} catch {
    Write-Error "Failed to start VM: $($_.Exception.Message)"
    exit 5
}

Write-Host "VM $VmName ($VmId) creation initiated. Check Proxmox task console or the UI for progress."

# Output a small JSON summary
$result = [pscustomobject]@{
    VmId   = $VmId
    VmName = $VmName
    Node   = $Node
    CreateTask = $resp.data
    StartTask  = $start.data
}

$result | ConvertTo-Json -Depth 4
