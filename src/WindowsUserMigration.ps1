[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [ValidateSet('Folders', 'Settings', 'Both')]
    [string]$Mode = 'Both'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Expand-ConfiguredPath {
    param([Parameter(Mandatory)][string]$Path)
    [Environment]::ExpandEnvironmentVariables($Path)
}

function Get-RequiredProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Configuration property '$Name' is required."
    }
    $property.Value
}

function New-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

function Invoke-SafeRobocopy {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][ValidateRange(1, 128)][int]$Threads
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        Write-Warning "Skipping missing folder: $Source"
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Destination, "Copy '$Source'")) { return }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $arguments = @($Source, $Destination, '/E', "/MT:$Threads", '/Z', '/R:2', '/W:2', '/XJ', '/COPY:DAT', '/DCOPY:DAT', '/NP')
    & robocopy.exe @arguments
    $exitCode = $LASTEXITCODE

    # Robocopy uses 0-7 for success and informational outcomes.
    if ($exitCode -gt 7) {
        throw "Robocopy failed with exit code $exitCode while copying '$Source'."
    }
}

function Export-DriveMappings {
    param([Parameter(Mandatory)][string]$Destination)
    $mappings = Get-CimInstance Win32_NetworkConnection -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.LocalName) } |
        Select-Object LocalName, RemoteName, UserName
    if ($mappings) {
        $mappings | Export-Csv -Path (Join-Path $Destination 'drive-mappings.csv') -NoTypeInformation -Encoding UTF8
    }
}

function Export-NetworkPrinters {
    param([Parameter(Mandatory)][string]$Destination)
    $printers = Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue |
        Where-Object { $_.Network } |
        Select-Object Name, ServerName, ShareName, DriverName
    if ($printers) {
        $printers | Export-Csv -Path (Join-Path $Destination 'network-printers.csv') -NoTypeInformation -Encoding UTF8
    }
}

function Copy-FileIfPresent {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$DestinationDirectory)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        Write-Verbose "Optional file not found: $Source"
        return
    }
    if ($PSCmdlet.ShouldProcess($DestinationDirectory, "Copy '$Source'")) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $DestinationDirectory -Force
    }
}

function Backup-Settings {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$UserProfile,
        [Parameter(Mandatory)][int]$Threads,
        [AllowEmptyString()][string]$OptionalRegistryKey
    )

    if (-not $PSCmdlet.ShouldProcess($Destination, 'Export Windows user settings')) { return }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Export-DriveMappings -Destination $Destination
    Export-NetworkPrinters -Destination $Destination

    Copy-FileIfPresent -Source (Join-Path $UserProfile 'AppData\Local\Google\Chrome\User Data\Default\Bookmarks') -DestinationDirectory (Join-Path $Destination 'Chrome')
    Copy-FileIfPresent -Source (Join-Path $UserProfile 'AppData\Roaming\Microsoft\Windows\Recent\AutomaticDestinations\f01b4d95cf55d32a.automaticDestinations-ms') -DestinationDirectory (Join-Path $Destination 'QuickAccess')

    $optionalFolders = @(
        @{ Source = 'AppData\LocalLow\Google\GoogleEarth'; Destination = 'GoogleEarth' },
        @{ Source = 'AppData\Local\TechSmith\Snagit\DataStore'; Destination = 'Snagit\DataStore' },
        @{ Source = 'AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState'; Destination = 'StickyNotes\LocalState' }
    )
    foreach ($folder in $optionalFolders) {
        Invoke-SafeRobocopy -Source (Join-Path $UserProfile $folder.Source) -Destination (Join-Path $Destination $folder.Destination) -Threads $Threads
    }

    if (-not [string]::IsNullOrWhiteSpace($OptionalRegistryKey)) {
        $registryOutput = Join-Path $Destination 'optional-registry-backup.reg'
        & reg.exe export $OptionalRegistryKey $registryOutput /y | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Registry export failed for '$OptionalRegistryKey'." }
    }
}

function Set-OptionalProfileAcl {
    param([Parameter(Mandatory)]$AclConfiguration, [Parameter(Mandatory)][string]$UserName)
    if ($null -eq $AclConfiguration -or -not $AclConfiguration.enabled) { return }

    $template = Get-RequiredProperty -Object $AclConfiguration -Name 'profilePathTemplate'
    $identity = Get-RequiredProperty -Object $AclConfiguration -Name 'identity'
    $rights = Get-RequiredProperty -Object $AclConfiguration -Name 'rights'
    $profilePath = (Expand-ConfiguredPath -Path $template).Replace('%USERNAME%', $UserName)

    if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
        Write-Warning "Configured roaming profile path does not exist: $profilePath"
        return
    }
    if ($PSCmdlet.ShouldProcess($profilePath, "Grant '$identity' '$rights'")) {
        $grant = '{0}:{1}' -f $identity, $rights
        & icacls.exe $profilePath /grant $grant /C | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE for '$profilePath'." }
    }
}

$configFile = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$destinationRoot = Expand-ConfiguredPath -Path (Get-RequiredProperty -Object $config -Name 'destinationRoot')
$userName = $env:USERNAME
$userProfile = [Environment]::GetFolderPath('UserProfile')

if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($userProfile)) {
    throw 'Unable to resolve the current Windows user profile.'
}

$threads = 16
if ($null -ne $config.PSObject.Properties['robocopyThreads']) { $threads = [int]$config.robocopyThreads }
if ($threads -lt 1 -or $threads -gt 128) { throw 'robocopyThreads must be between 1 and 128.' }

$destination = Join-Path $destinationRoot $userName
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
if (Test-Path -LiteralPath $destination) {
    $archive = "$destination-$timestamp"
    if ($PSCmdlet.ShouldProcess($destination, "Archive existing destination as '$archive'")) {
        Move-Item -LiteralPath $destination -Destination $archive
    }
}
New-Directory -Path $destination

$transcriptStarted = $false
try {
    if (-not $WhatIfPreference) {
        Start-Transcript -Path (Join-Path $destination 'migration.log') -Force | Out-Null
        $transcriptStarted = $true
    }

    Write-Host "Starting user migration backup for '$userName' in mode '$Mode'."

    if ($Mode -in @('Folders', 'Both')) {
        $configuredFolders = @('Desktop', 'Documents', 'Downloads')
        if ($null -ne $config.PSObject.Properties['folders']) { $configuredFolders = @($config.folders) }
        foreach ($folderName in $configuredFolders) {
            if ($folderName -notin @('Desktop', 'Documents', 'Downloads')) {
                throw "Unsupported profile folder '$folderName'. Allowed values: Desktop, Documents, Downloads."
            }
            Invoke-SafeRobocopy -Source (Join-Path $userProfile $folderName) -Destination (Join-Path $destination $folderName) -Threads $threads
        }
    }

    if ($Mode -in @('Settings', 'Both')) {
        $registryKey = ''
        if ($null -ne $config.PSObject.Properties['optionalRegistryKey']) { $registryKey = [string]$config.optionalRegistryKey }
        Backup-Settings -Destination (Join-Path $destination 'Settings') -UserProfile $userProfile -Threads $threads -OptionalRegistryKey $registryKey
    }

    if ($null -ne $config.PSObject.Properties['roamingProfileAcl']) {
        Set-OptionalProfileAcl -AclConfiguration $config.roamingProfileAcl -UserName $userName
    }
    Write-Host "Migration backup completed: $destination"
}
finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
}
