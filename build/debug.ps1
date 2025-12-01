# Get the latest tag from the remote repository (excluding testing tags)
git fetch --tags
$latestTag = git tag -l | Where-Object { $_ -notmatch '^testing_' } | Sort-Object -Descending | Select-Object -First 1

if (-not $latestTag) {
    Write-Host "No existing tags found. Using version 1.0.0.0"
    $version = "1.0.0.0"
} else {
    Write-Host "Latest tag: $latestTag"
    $version = $latestTag
}

Write-Host "Building with version: $version"

# Get the repository root (parent of scripts folder)
$scriptDir = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptDir

# Auto-detect project identifiers so this script works for any repo
Write-Host "Auto-detecting project files..."
# Find a solution file (if present)
$sln = Get-ChildItem -Path $repoRoot -Filter *.sln -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } | Select-Object -First 1
if ($sln) {
    $SolutionName = $sln.Name
    Write-Host "Found solution: $SolutionName"
} else {
    $SolutionName = $null
    Write-Host "No .sln found; will build project file directly."
}

# Find a project file (.csproj)
$csprojFile = Get-ChildItem -Path $repoRoot -Filter *.csproj -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } | Select-Object -First 1
if (-not $csprojFile) {
    Write-Error "No .csproj file found in repository."
    exit 1
}
$CsprojName = $csprojFile.Name
$ProjectDirFull = $csprojFile.Directory.FullName
$ProjectDir = Split-Path $ProjectDirFull -Leaf
Write-Host "Using project dir: $ProjectDir; csproj: $CsprojName"

# Find a project JSON file (look in project folder then repo root) that contains AssemblyVersion
$JsonName = $null
$projJsons = Get-ChildItem -Path $ProjectDirFull -Filter *.json -ErrorAction SilentlyContinue
foreach ($j in $projJsons) {
    $content = Get-Content $j.FullName -Raw -ErrorAction SilentlyContinue
    if ($content -and $content -match 'AssemblyVersion') { $JsonName = $j.Name; break }
}
if (-not $JsonName) {
    $rootJsons = Get-ChildItem -Path $repoRoot -Filter *.json -ErrorAction SilentlyContinue
    foreach ($j in $rootJsons) {
        if ($j.Name -ieq 'repo.json') { continue }
        $content = Get-Content $j.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -and $content -match 'AssemblyVersion') { $JsonName = $j.Name; break }
    }
}
if (-not $JsonName) { $JsonName = 'ProjectInfo.json'; Write-Host "No project json found; defaulting to $JsonName" } else { Write-Host "Using project json: $JsonName" }

$csprojPath = $csprojFile.FullName
Write-Host "Updating $CsprojName at $csprojPath..."
$csproj = Get-Content $csprojPath -Raw
$csproj = $csproj -replace '<FileVersion>[\d\.]+</FileVersion>', "<FileVersion>$version</FileVersion>"
$csproj = $csproj -replace '<AssemblyVersion>[\d\.]+</AssemblyVersion>', "<AssemblyVersion>$version</AssemblyVersion>"
Set-Content -Path $csprojPath -Value $csproj -NoNewline

$projectJsonPath = if (Test-Path (Join-Path $ProjectDirFull $JsonName)) { Join-Path $ProjectDirFull $JsonName } else { Join-Path $repoRoot $JsonName }
Write-Host "Updating $JsonName at $projectJsonPath..."
$projectJson = Get-Content $projectJsonPath -Raw | ConvertFrom-Json
$projectJson.AssemblyVersion = $version
$projectJson | ConvertTo-Json -Depth 10 | Set-Content -Path $projectJsonPath

# Update version in repo.json
Write-Host "Updating repo.json..."
$repoJsonPath = Join-Path $repoRoot "repo.json"
$repoJsonRaw = Get-Content $repoJsonPath -Raw
$repoJson = $repoJsonRaw | ConvertFrom-Json
# Ensure repoJson is always an array
if ($repoJson -isnot [System.Collections.IEnumerable] -or $repoJson -is [string]) {
    $repoJson = @($repoJson)
}
$repoJson[0].AssemblyVersion = $version
$repoJson[0].TestingAssemblyVersion = $version
$repoJsonJson = $repoJson | ConvertTo-Json -Depth 10
$trimmed = $repoJsonJson.Trim()
$nl = [Environment]::NewLine
if ($trimmed.StartsWith('{')) {
    $repoJsonJson = '[' + $nl + $repoJsonJson + $nl + ']'
}
Set-Content -Path $repoJsonPath -Value $repoJsonJson

# Build the project in Debug mode
Write-Host "Building in Debug mode..."
if ($SolutionName) { $slnPath = Join-Path $repoRoot $SolutionName } else { $slnPath = $csprojPath }
dotnet build $slnPath -c Debug

# Revert the version changes
Write-Host "Reverting version changes..."
git checkout -- $csprojPath $projectJsonPath $repoJsonPath

Write-Host "Build complete! Version: $version"
