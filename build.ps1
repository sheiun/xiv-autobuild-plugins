[CmdletBinding()]
Param(
    [Parameter(Position=0,Mandatory=$false,ValueFromRemainingArguments=$true)]
    [string[]]$BuildArguments
)

Write-Output "PowerShell $($PSVersionTable.PSEdition) version $($PSVersionTable.PSVersion)"

Set-StrictMode -Version 2.0; $ErrorActionPreference = "Stop"; $ConfirmPreference = "None"; trap { Write-Error $_ -ErrorAction Continue; exit 1 }
$PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent

###########################################################################
# CONFIGURATION
###########################################################################

# Auto-search for .csproj file by reading .sln file first
$BuildProjectFile = $null

# Function to parse solution file and extract project paths
function Get-ProjectsFromSolution($solutionPath) {
    $projects = @()
    $solutionDir = Split-Path $solutionPath -Parent
    $content = Get-Content $solutionPath -ErrorAction SilentlyContinue
    
    foreach ($line in $content) {
        # Match project lines: Project("{GUID}") = "Name", "path\to\project.csproj", "{GUID}"
        # Example: Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "Chroma", "Chroma\Chroma.csproj", "{GUID}"
        if ($line -match '^Project\(') {
            # Extract the project path (second quoted string after the equals sign)
            # Pattern: Project(...) = "Name", "Path\To\Project.csproj", "{GUID}"
            # Match: Project("{GUID}") = "Name", "Path\To\Project.csproj", "{GUID}"
            if ($line -match '=\s*"[^"]*",\s*"([^"]+\.csproj)"') {
                $projectPath = $matches[1]
                
                # Validate we got a proper path
                if ($projectPath -and $projectPath.Length -gt 4 -and $projectPath.EndsWith(".csproj")) {
                    # Convert relative path to absolute (handle both \ and / separators)
                    $projectPath = $projectPath -replace '/', '\'
                    
                    # Resolve path relative to solution directory
                    if ([System.IO.Path]::IsPathRooted($projectPath)) {
                        $fullPath = $projectPath
                    } else {
                        $fullPath = Join-Path $solutionDir $projectPath
                    }
                    
                    # Normalize the path
                    try {
                        $fullPath = [System.IO.Path]::GetFullPath($fullPath)
                        # Validate the path is reasonable before adding
                        if ($fullPath -and $fullPath.Length -gt 10 -and $fullPath.EndsWith(".csproj") -and (Test-Path $fullPath)) {
                            $projects += $fullPath
                        } else {
                            Write-Warning "Skipping invalid or non-existent project path: $fullPath"
                        }
                    } catch {
                        # Skip invalid paths
                        Write-Warning "Skipping invalid project path: $projectPath - Error: $_"
                    }
                }
            }
        }
    }
    return $projects
}

# First, try to find and parse .sln files (most common case)
$solutionFiles = Get-ChildItem -Path $PSScriptRoot -Filter "*.sln" -ErrorAction SilentlyContinue

if ($solutionFiles) {
    foreach ($sln in $solutionFiles) {
        $projects = Get-ProjectsFromSolution $sln.FullName
        
        if ($projects -and $projects.Count -gt 0) {
            # Use the first project from the solution file
            $selectedProject = $projects[0]
            if ($selectedProject -is [string]) {
                $BuildProjectFile = $selectedProject
            } else {
                $BuildProjectFile = $selectedProject.ToString()
            }
            break
        }
    }
}

# If no solution file or no projects found, search for .csproj files directly
if ($null -eq $BuildProjectFile) {
    # First check root directory for any .csproj
    $foundFiles = Get-ChildItem -Path $PSScriptRoot -Filter "*.csproj" -ErrorAction SilentlyContinue
    if ($foundFiles) {
        $BuildProjectFile = $foundFiles[0].FullName
    }
}

# If still not found, search recursively (excluding build artifacts)
if ($null -eq $BuildProjectFile) {
    $foundFiles = Get-ChildItem -Path $PSScriptRoot -Filter "*.csproj" -Recurse -ErrorAction SilentlyContinue | 
        Where-Object { 
            $_.FullName -notlike "*\.nuke\*" -and 
            $_.FullName -notlike "*\bin\*" -and 
            $_.FullName -notlike "*\obj\*" -and
            $_.FullName -notlike "*\node_modules\*"
        }
    
    if ($foundFiles) {
        # Use the first .csproj file found
        $BuildProjectFile = $foundFiles[0].FullName
    }
}

# If still not found, use default path
if ($null -eq $BuildProjectFile) {
    $BuildProjectFile = "$PSScriptRoot\build\build.csproj"
    Write-Warning ".csproj file not found, using default path: $BuildProjectFile"
}

# Validate the path before using it
if ($null -eq $BuildProjectFile -or $BuildProjectFile -eq "") {
    Write-Error "Could not determine build project file"
    exit 1
}

# Ensure we have a string, not a character or other type
$BuildProjectFile = $BuildProjectFile.ToString().Trim()

# Validate it's a reasonable path (not just a single character)
if ($BuildProjectFile.Length -lt 5 -or -not $BuildProjectFile.EndsWith(".csproj")) {
    Write-Error "Invalid build project path (too short or not a .csproj file): $BuildProjectFile"
    exit 1
}

try {
    $BuildProjectFile = [System.IO.Path]::GetFullPath($BuildProjectFile)
    if (-not (Test-Path $BuildProjectFile)) {
        Write-Error "Build project file does not exist: $BuildProjectFile"
        exit 1
    }
} catch {
    Write-Error "Invalid build project path: $BuildProjectFile - Error: $_"
    exit 1
}

Write-Output "Using build project: $BuildProjectFile"

$TempDirectory = "$PSScriptRoot\\.nuke\temp"

$DotNetGlobalFile = "$PSScriptRoot\\global.json"
$DotNetInstallUrl = "https://dot.net/v1/dotnet-install.ps1"
$DotNetChannel = "Current"

$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = 1
$env:DOTNET_CLI_TELEMETRY_OPTOUT = 1
$env:DOTNET_MULTILEVEL_LOOKUP = 0

###########################################################################
# EXECUTION
###########################################################################

function ExecSafe([scriptblock] $cmd) {
    & $cmd
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}

# If dotnet CLI is installed globally and it matches requested version, use for execution
if ($null -ne (Get-Command "dotnet" -ErrorAction SilentlyContinue) -and `
     $(dotnet --version) -and $LASTEXITCODE -eq 0) {
    $env:DOTNET_EXE = (Get-Command "dotnet").Path
}
else {
    # Download install script
    $DotNetInstallFile = "$TempDirectory\dotnet-install.ps1"
    New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile($DotNetInstallUrl, $DotNetInstallFile)

    # If global.json exists, load expected version
    if (Test-Path $DotNetGlobalFile) {
        $DotNetGlobal = $(Get-Content $DotNetGlobalFile | Out-String | ConvertFrom-Json)
        if ($DotNetGlobal.PSObject.Properties["sdk"] -and $DotNetGlobal.sdk.PSObject.Properties["version"]) {
            $DotNetVersion = $DotNetGlobal.sdk.version
        }
    }

    # Install by channel or version
    $DotNetDirectory = "$TempDirectory\dotnet-win"
    if (!(Test-Path variable:DotNetVersion)) {
        ExecSafe { & $DotNetInstallFile -InstallDir $DotNetDirectory -Channel $DotNetChannel -NoPath }
    } else {
        ExecSafe { & $DotNetInstallFile -InstallDir $DotNetDirectory -Version $DotNetVersion -NoPath }
    }
    $env:DOTNET_EXE = "$DotNetDirectory\dotnet.exe"
}

Write-Output "Microsoft (R) .NET Core SDK version $(& $env:DOTNET_EXE --version)"

ExecSafe { & $env:DOTNET_EXE build $BuildProjectFile /nodeReuse:false /p:UseSharedCompilation=false -nologo -clp:NoSummary --verbosity quiet }
ExecSafe { & $env:DOTNET_EXE run --project $BuildProjectFile --no-build -- $BuildArguments }