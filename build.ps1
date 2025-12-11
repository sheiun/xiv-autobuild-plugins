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
            if ($line -match '=\s*"[^"]*",\s*"([^"]+\.csproj)"') {
                $projectPath = $matches[1]
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
                    if (Test-Path $fullPath) {
                        $projects += $fullPath
                    }
                } catch {
                    # Skip invalid paths
                }
            }
        }
    }
    return $projects
}

# First, try to find build projects directly (build directory or *build*.csproj)
# This is for Nuke build systems where build.csproj is typically not in the solution
$buildDirs = @(
    "$PSScriptRoot\build",
    $PSScriptRoot
)

foreach ($dir in $buildDirs) {
    if (Test-Path $dir) {
        # Search for *build*.csproj files
        $foundFiles = Get-ChildItem -Path $dir -Filter "*build*.csproj" -ErrorAction SilentlyContinue
        if ($foundFiles) {
            $BuildProjectFile = $foundFiles[0].FullName
            break
        }
        # Also check for any .csproj in build directory
        if ($dir -like "*\build") {
            $foundFiles = Get-ChildItem -Path $dir -Filter "*.csproj" -ErrorAction SilentlyContinue
            if ($foundFiles) {
                $BuildProjectFile = $foundFiles[0].FullName
                break
            }
        }
    }
}

# If no build project found directly, try to find and parse .sln files
if ($null -eq $BuildProjectFile) {
    $solutionFiles = Get-ChildItem -Path $PSScriptRoot -Filter "*.sln" -ErrorAction SilentlyContinue

    if ($solutionFiles) {
        foreach ($sln in $solutionFiles) {
            $projects = Get-ProjectsFromSolution $sln.FullName
            
            if ($projects) {
                # Prefer projects in "build" directory or with "build" in name
                $buildProjects = $projects | Where-Object { 
                    $_ -like "*\build\*" -or 
                    (Split-Path $_ -Leaf) -like "*build*.csproj" 
                }
                
                if ($buildProjects) {
                    $BuildProjectFile = $buildProjects[0]
                    break
                } else {
                    # If no build project in solution, use first project found
                    # (Note: This might not be the build project for Nuke-based repos)
                    $BuildProjectFile = $projects[0]
                    break
                }
            }
        }
    }
}

# Fallback: Search in common locations if .sln parsing didn't work
if ($null -eq $BuildProjectFile) {
    $SearchDirectories = @(
        "$PSScriptRoot\build",
        $PSScriptRoot
    )

    foreach ($dir in $SearchDirectories) {
        if (Test-Path $dir) {
            $foundFiles = Get-ChildItem -Path $dir -Filter "*.csproj" -ErrorAction SilentlyContinue
            if ($foundFiles) {
                $BuildProjectFile = $foundFiles[0].FullName
                break
            }
        }
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
        # Prefer files in a "build" directory if multiple found
        $buildDirFiles = $foundFiles | Where-Object { $_.DirectoryName -like "*\build" }
        if ($buildDirFiles) {
            $BuildProjectFile = $buildDirFiles[0].FullName
        } else {
            $BuildProjectFile = $foundFiles[0].FullName
        }
    }
}

# If still not found, use default path
if ($null -eq $BuildProjectFile) {
    $BuildProjectFile = "$PSScriptRoot\build\build.csproj"
    Write-Warning ".csproj file not found, using default path: $BuildProjectFile"
}

# Validate the path before using it
if ($null -ne $BuildProjectFile) {
    try {
        $BuildProjectFile = [System.IO.Path]::GetFullPath($BuildProjectFile)
        if (-not (Test-Path $BuildProjectFile)) {
            Write-Error "Build project file does not exist: $BuildProjectFile"
            exit 1
        }
    } catch {
        Write-Error "Invalid build project path: $BuildProjectFile"
        exit 1
    }
} else {
    Write-Error "Could not determine build project file"
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