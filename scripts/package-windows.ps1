#Requires -Version 7.3
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$metadata = Get-Content -Raw -LiteralPath (Join-Path $root 'version.json') | ConvertFrom-Json
if ($metadata.version -notmatch '^\d+\.\d+(\.\d+)?$' -or $metadata.build -notmatch '^[1-9]\d*$') {
    throw 'Invalid version or build number in version.json.'
}

$dist = Join-Path $root 'dist'
[IO.Directory]::CreateDirectory($dist) | Out-Null
$name = "近星点-$($metadata.version)-build$($metadata.build)-Windows-x64.zip"
$stage = [IO.Directory]::CreateTempSubdirectory('perihel-package-')
try {
    $publish = Join-Path $stage.FullName 'publish'
    dotnet publish (Join-Path $root 'src/windows/Perihel.csproj') -c Release -r win-x64 --self-contained true -o $publish
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)." }

    foreach ($required in 'Perihel.exe', 'Perihel.pri', 'version.json', 'coreclr.dll') {
        if (!(Test-Path -LiteralPath (Join-Path $publish $required) -PathType Leaf)) {
            throw "Missing published file: $required"
        }
    }
    $archive = Join-Path $stage.FullName $name
    [IO.Compression.ZipFile]::CreateFromDirectory($publish, $archive)
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$archive.sha256", "$hash  $name`n")
    Move-Item -LiteralPath $archive, "$archive.sha256" -Destination $dist -Force
} finally {
    $tempRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetTempPath())
    if ($stage.Parent.FullName -eq $tempRoot -and $stage.Name.StartsWith('perihel-package-')) {
        $stage.Delete($true)
    }
}
