<#
.SYNOPSIS
    Pre-Analyzer — Extracts code structure before question generation.
    Uses regex-based parsing (no external AST tools required) to extract
    function signatures, class hierarchies, imports, and route decorators.

.DESCRIPTION
    Provides deterministic code structure extraction that monkeys can use
    to generate more targeted questions. Works across languages without
    requiring language-specific tooling.

.NOTES
    Part of the Playbook framework.
#>

Set-StrictMode -Version Latest

function Get-CodeStructure {
    <#
    .SYNOPSIS
        Extracts structural information from a source file.
        Returns functions, classes, imports, routes, and complexity estimate.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string]$Language
    )

    if (-not (Test-Path $FilePath)) { return $null }
    $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $null }

    # Auto-detect language from extension if not provided
    if (-not $Language) {
        $ext = [System.IO.Path]::GetExtension($FilePath).TrimStart('.')
        $Language = switch ($ext) {
            'cs'    { 'csharp' }
            'py'    { 'python' }
            'ts'    { 'typescript' }
            'js'    { 'javascript' }
            'go'    { 'go' }
            'java'  { 'java' }
            'rb'    { 'ruby' }
            default { 'unknown' }
        }
    }

    $structure = @{
        FilePath     = $FilePath
        Language     = $Language
        LineCount    = ($content -split "`n").Count
        Functions    = @()
        Classes      = @()
        Imports      = @()
        Routes       = @()
        Complexity   = 0
        Decorators   = @()
    }

    switch ($Language) {
        'csharp' {
            # Classes
            $structure.Classes = @([regex]::Matches($content, '(?:public|internal|private|protected)\s+(?:abstract\s+|sealed\s+|static\s+|partial\s+)*class\s+(\w+)') | ForEach-Object { $_.Groups[1].Value })

            # Methods with signatures
            $structure.Functions = @([regex]::Matches($content, '(?:public|internal|private|protected)\s+(?:static\s+|virtual\s+|override\s+|async\s+)*[\w<>\[\],\s]+?\s+(\w+)\s*\([^)]*\)') | ForEach-Object {
                @{ Name = $_.Groups[1].Value; Signature = $_.Value.Trim() }
            })

            # Using statements
            $structure.Imports = @([regex]::Matches($content, 'using\s+([\w.]+)\s*;') | ForEach-Object { $_.Groups[1].Value })

            # Route attributes
            $structure.Routes = @([regex]::Matches($content, '\[(?:Http(?:Get|Post|Put|Delete|Patch)|Route)\s*\(\s*"([^"]+)"\s*\)\]') | ForEach-Object {
                @{ Route = $_.Groups[1].Value; Attribute = $_.Value }
            })

            # Decorators/Attributes
            $structure.Decorators = @([regex]::Matches($content, '\[(\w+)(?:\([^)]*\))?\]') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        }

        'python' {
            $structure.Classes = @([regex]::Matches($content, 'class\s+(\w+)') | ForEach-Object { $_.Groups[1].Value })
            $structure.Functions = @([regex]::Matches($content, 'def\s+(\w+)\s*\(([^)]*)\)') | ForEach-Object {
                @{ Name = $_.Groups[1].Value; Params = $_.Groups[2].Value }
            })
            $structure.Imports = @([regex]::Matches($content, '(?:from\s+(\S+)\s+)?import\s+(.+)') | ForEach-Object { $_.Value.Trim() })
            $structure.Routes = @([regex]::Matches($content, '@(?:app|router|api)\.\s*(?:get|post|put|delete|patch|route)\s*\(\s*[''"]([^''"]+)[''"]') | ForEach-Object {
                @{ Route = $_.Groups[1].Value }
            })
            $structure.Decorators = @([regex]::Matches($content, '@(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        }

        'typescript' {
            $structure.Classes = @([regex]::Matches($content, 'class\s+(\w+)') | ForEach-Object { $_.Groups[1].Value })
            $structure.Functions = @([regex]::Matches($content, '(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(|(\w+)\s*(?::\s*\([^)]*\)\s*=>|=\s*(?:async\s+)?\([^)]*\)\s*=>)') | ForEach-Object {
                $name = if ($_.Groups[1].Value) { $_.Groups[1].Value } else { $_.Groups[2].Value }
                @{ Name = $name }
            })
            $structure.Imports = @([regex]::Matches($content, 'import\s+.+\s+from\s+[''"]([^''"]+)[''"]') | ForEach-Object { $_.Groups[1].Value })
            $structure.Routes = @([regex]::Matches($content, '(?:app|router)\.\s*(?:get|post|put|delete|patch)\s*\(\s*[''"]([^''"]+)[''"]') | ForEach-Object {
                @{ Route = $_.Groups[1].Value }
            })
        }

        'go' {
            $structure.Functions = @([regex]::Matches($content, 'func\s+(?:\(\w+\s+\*?\w+\)\s+)?(\w+)\s*\(') | ForEach-Object {
                @{ Name = $_.Groups[1].Value }
            })
            $structure.Imports = @([regex]::Matches($content, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match '/' })
            $structure.Routes = @([regex]::Matches($content, '(?:HandleFunc|Handle|Get|Post|Put|Delete)\s*\(\s*"([^"]+)"') | ForEach-Object {
                @{ Route = $_.Groups[1].Value }
            })
        }

        'java' {
            $structure.Classes = @([regex]::Matches($content, '(?:public|private|protected)\s+(?:abstract\s+|final\s+)?class\s+(\w+)') | ForEach-Object { $_.Groups[1].Value })
            $structure.Functions = @([regex]::Matches($content, '(?:public|private|protected)\s+(?:static\s+)?[\w<>\[\]]+\s+(\w+)\s*\(') | ForEach-Object {
                @{ Name = $_.Groups[1].Value }
            })
            $structure.Imports = @([regex]::Matches($content, 'import\s+([\w.]+)\s*;') | ForEach-Object { $_.Groups[1].Value })
            $structure.Routes = @([regex]::Matches($content, '@(?:Get|Post|Put|Delete|Patch|Request)Mapping\s*\(\s*(?:value\s*=\s*)?[''"]([^''"]+)[''"]') | ForEach-Object {
                @{ Route = $_.Groups[1].Value }
            })
            $structure.Decorators = @([regex]::Matches($content, '@(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        }
    }

    # Complexity estimate (language-agnostic heuristics)
    $branchCount = ([regex]::Matches($content, '\b(if|else|switch|case|for|foreach|while|do|catch|try)\b')).Count
    $nestingMax = 0
    $currentNesting = 0
    foreach ($char in $content.ToCharArray()) {
        if ($char -eq '{') { $currentNesting++; if ($currentNesting -gt $nestingMax) { $nestingMax = $currentNesting } }
        elseif ($char -eq '}') { $currentNesting = [Math]::Max(0, $currentNesting - 1) }
    }
    $structure.Complexity = @{
        BranchCount  = $branchCount
        MaxNesting   = $nestingMax
        Score        = [Math]::Round(($branchCount * 0.3 + $nestingMax * 0.7 + $structure.Functions.Count * 0.2), 1)
    }

    return $structure
}

function Get-PreAnalysisSummary {
    <#
    .SYNOPSIS
        Runs pre-analysis on multiple entry points and returns a summary.
        Used by monkeys to generate better-targeted questions.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$EntryPoints,

        [string]$WorkingDirectory
    )

    $results = @()
    foreach ($ep in $EntryPoints) {
        $path = if ($ep.Path) { $ep.Path } else { Join-Path $WorkingDirectory $ep.RelPath }
        $lang = if ($ep.Language -and $ep.Language -ne 'custom') { $ep.Language } else { $null }
        $structure = Get-CodeStructure -FilePath $path -Language $lang
        if ($structure) {
            $results += @{
                EntryPoint  = $ep.RelPath
                Language    = $structure.Language
                Lines       = $structure.LineCount
                Classes     = $structure.Classes.Count
                Functions   = $structure.Functions.Count
                Routes      = $structure.Routes.Count
                Imports     = $structure.Imports.Count
                Complexity  = $structure.Complexity.Score
                TopMethods  = @($structure.Functions | Select-Object -First 10 | ForEach-Object { $_.Name })
                RouteList   = @($structure.Routes | ForEach-Object { $_.Route })
            }
        }
    }

    # Sort by complexity descending — most complex files get more attention
    $results = $results | Sort-Object { $_.Complexity } -Descending

    return $results
}

Export-ModuleMember -Function @(
    'Get-CodeStructure'
    'Get-PreAnalysisSummary'
)
