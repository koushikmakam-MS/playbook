<#
.SYNOPSIS
    DocRegistry.psm1 — Deterministic doc_registry builder for the Monkey Army framework
.DESCRIPTION
    Replaces LLM-generated doc_registry.md with a scripted, deterministic version.
    Scans source code for controllers/handlers, cross-references workflow docs,
    and produces a coverage registry with per-layer breakdown.
    Manages .doc-changes.log for mid-run change tracking.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\DocLayers.psm1" -Force

# ═══════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════

$script:ControllerPatterns = @(
    '*Controller.cs'
    '*Handler.cs'
    '*Controller.py'
    '*_handler.py'
    '*Router.ts'
    '*Controller.java'
    '*_controller.go'
)

$script:ExcludeDirs = @('node_modules', 'bin', 'obj', '.git', 'vendor', 'dist', '__pycache__')

$script:StandardSections = @(
    '## 1. Overview'
    '## 2. Trigger Points'
    '## 3. API Endpoints'
    '## 4. Request/Response'
    '## 5. Sequence Diagram'
    '## 6. Key Source Files'
    '## 7. Configuration'
    '## 8. Telemetry'
    '## 9. How to Debug'
    '## 10. Error Scenarios'
)

# ═══════════════════════════════════════════════════════════════
# PRIVATE HELPERS
# ═══════════════════════════════════════════════════════════════

function Get-RelativePath {
    param(
        [string]$FullPath,
        [string]$BasePath
    )
    $normFull = $FullPath.Replace('\', '/')
    $normBase = $BasePath.Replace('\', '/').TrimEnd('/')

    if ($normFull.StartsWith($normBase + '/')) {
        return $normFull.Substring($normBase.Length + 1)
    }
    return $normFull
}

function Extract-ClassName {
    param([string]$FileName)
    # Strip extension, then common suffixes for clean name
    $name = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    return $name
}

# ═══════════════════════════════════════════════════════════════
# PUBLIC FUNCTIONS — EXPORTED
# ═══════════════════════════════════════════════════════════════

function Get-ControllerList {
    <#
    .SYNOPSIS
        Scan source code for entry points (controllers, handlers, routes).
    .PARAMETER RepoPath
        Root path of the repository to scan.
    .OUTPUTS
        Array of hashtables: Name, FilePath, RelPath, Domain
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RepoPath
    )

    if (-not (Test-Path $RepoPath)) { return @() }

    $results = @()
    $allFiles = Get-ChildItem $RepoPath -Recurse -File -ErrorAction SilentlyContinue

    # Filter out excluded directories
    $filtered = $allFiles | Where-Object {
        $filePath = $_.FullName.Replace('\', '/')
        $excluded = $false
        foreach ($dir in $script:ExcludeDirs) {
            if ($filePath -match "[\\/]$([regex]::Escape($dir))[\\/]") {
                $excluded = $true
                break
            }
        }
        -not $excluded
    }

    foreach ($file in $filtered) {
        $matched = $false
        foreach ($pattern in $script:ControllerPatterns) {
            if ($file.Name -like $pattern) {
                $matched = $true
                break
            }
        }
        if ($matched) {
            $className = Extract-ClassName -FileName $file.Name
            $relPath = Get-RelativePath -FullPath $file.FullName -BasePath $RepoPath
            $results += @{
                Name     = $className
                FilePath = $file.FullName.Replace('\', '/')
                RelPath  = $relPath
                Domain   = $null
            }
        }
    }

    return $results
}

function Get-WorkflowDocs {
    <#
    .SYNOPSIS
        Scan workflow docs and count standard sections present.
    .PARAMETER DocsRoot
        Path to the docs directory (e.g., docs/agentKT).
    .OUTPUTS
        Array of hashtables with doc path, section counts, and controller references.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$DocsRoot
    )

    $wfDir = Join-Path $DocsRoot "workflows"
    if (-not (Test-Path $wfDir)) { return @() }

    $mdFiles = Get-ChildItem $wfDir -Filter '*.md' -File -ErrorAction SilentlyContinue
    if (-not $mdFiles) { return @() }

    $results = @()
    foreach ($file in $mdFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { $content = '' }

        # Count standard sections
        $present = @()
        $missing = @()
        foreach ($section in $script:StandardSections) {
            $escaped = [regex]::Escape($section)
            if ($content -match $escaped) {
                $present += $section
            }
            else {
                $missing += $section
            }
        }

        # Check for mermaid block (the +1 in 10+1)
        $hasMermaid = $content -match '```mermaid'
        if ($hasMermaid) {
            $present += '```mermaid'
        }
        else {
            $missing += '```mermaid'
        }

        $sectionsTotal = 11  # 10 standard sections + mermaid

        # Grep for controller class name references (class names without extensions)
        $controllersReferenced = @()
        # Extract suffix patterns: Controller, Handler, Router, _handler, _controller
        $suffixes = @('Controller', 'Handler', 'Router', '_handler', '_controller')
        foreach ($suffix in $suffixes) {
            $regexMatches = [regex]::Matches($content, '\b(\w+' + [regex]::Escape($suffix) + ')\b')
            foreach ($m in $regexMatches) {
                $name = $m.Groups[1].Value
                if ($controllersReferenced -notcontains $name) {
                    $controllersReferenced += $name
                }
            }
        }

        $relPath = Get-RelativePath -FullPath $file.FullName -BasePath $DocsRoot
        $results += @{
            DocPath               = $file.FullName.Replace('\', '/')
            RelPath               = $relPath
            FileName              = $file.Name
            SectionsPresent       = $present
            SectionsTotal         = $sectionsTotal
            MissingSections       = $missing
            ControllersReferenced = $controllersReferenced
        }
    }

    return $results
}

function Build-DocRegistry {
    <#
    .SYNOPSIS
        Main registry builder — produces doc_registry.md deterministically.
    .PARAMETER RepoPath
        Repository root path.
    .PARAMETER DocsRoot
        Path to docs directory (e.g., docs/agentKT).
    .PARAMETER ChangeLogPath
        Optional path to .doc-changes.log for merge metadata.
    .OUTPUTS
        Hashtable with TotalControllers, Documented, Undocumented, CoveragePct, LayerSummary, DocPath.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RepoPath,
        [Parameter(Mandatory)]
        [string]$DocsRoot,
        [string]$ChangeLogPath
    )

    # a. Controller ground truth
    $controllers = @(Get-ControllerList -RepoPath $RepoPath)

    # b. Doc inventory with section counts
    $workflowDocs = @(Get-WorkflowDocs -DocsRoot $DocsRoot)

    # c. Cross-reference: documented vs undocumented
    $allReferenced = @()
    foreach ($doc in $workflowDocs) {
        $allReferenced += $doc.ControllersReferenced
    }
    $allReferenced = @($allReferenced | Select-Object -Unique)

    $documented = @()
    $undocumented = @()
    foreach ($ctrl in $controllers) {
        if ($allReferenced -contains $ctrl.Name) {
            $documented += $ctrl
        }
        else {
            $undocumented += $ctrl
        }
    }

    # d. Merge change log metadata if available
    $changeEntries = @()
    if ($ChangeLogPath -and (Test-Path $ChangeLogPath)) {
        $changeEntries = @(Read-ChangeLog -ChangeLogPath $ChangeLogPath)
    }

    # e. Per-layer coverage via DocLayers
    $allLayers = @(Get-AllDocLayers -DocsRoot $DocsRoot -RepoPath $RepoPath)
    $layerSummary = Get-LayerSummary -DocLayers $allLayers

    # f. Build markdown output
    $totalControllers = $controllers.Count
    $documentedCount = $documented.Count
    $undocumentedCount = $undocumented.Count
    $coveragePct = if ($totalControllers -gt 0) {
        [math]::Round(($documentedCount / $totalControllers) * 100, 1)
    } else { 0 }

    $lines = @()
    $lines += '# Doc Registry'
    $lines += ''
    $lines += "> Auto-generated by DocRegistry.psm1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ''

    # ── Documented Controllers ──
    $lines += '## Documented Controllers'
    $lines += ''
    if ($documented.Count -gt 0) {
        $lines += '| Controller | Source Path | Referenced In |'
        $lines += '|-----------|------------|---------------|'
        foreach ($ctrl in $documented) {
            $referencedDocs = @()
            foreach ($doc in $workflowDocs) {
                if ($doc.ControllersReferenced -contains $ctrl.Name) {
                    $referencedDocs += $doc.FileName
                }
            }
            $refStr = ($referencedDocs -join ', ')
            $lines += "| $($ctrl.Name) | ``$($ctrl.RelPath)`` | $refStr |"
        }
    }
    else {
        $lines += '_No documented controllers found._'
    }
    $lines += ''

    # ── Undocumented Controllers ──
    $lines += '## Undocumented Controllers'
    $lines += ''
    if ($undocumented.Count -gt 0) {
        $lines += '| Controller | Source Path |'
        $lines += '|-----------|------------|'
        foreach ($ctrl in $undocumented) {
            $lines += "| $($ctrl.Name) | ``$($ctrl.RelPath)`` |"
        }
    }
    else {
        $lines += '_All controllers are documented._'
    }
    $lines += ''

    # ── Section Completeness ──
    $lines += '## Section Completeness'
    $lines += ''
    if ($workflowDocs.Count -gt 0) {
        $lines += '| Document | Sections | Missing |'
        $lines += '|----------|----------|---------|'
        foreach ($doc in $workflowDocs) {
            $presentCount = $doc.SectionsPresent.Count
            $total = $doc.SectionsTotal
            $missingStr = if ($doc.MissingSections.Count -gt 0) {
                ($doc.MissingSections -join '; ')
            } else { '—' }
            $lines += "| $($doc.FileName) | $presentCount/$total | $missingStr |"
        }
    }
    else {
        $lines += '_No workflow docs found._'
    }
    $lines += ''

    # ── Change Log ──
    if ($changeEntries.Count -gt 0) {
        $lines += '## Recent Changes'
        $lines += ''
        $lines += '| Action | Document | Details | Date |'
        $lines += '|--------|----------|---------|------|'
        foreach ($entry in $changeEntries) {
            $lines += "| $($entry.Action) | $($entry.DocPath) | $($entry.Details) | $($entry.Date) |"
        }
        $lines += ''
    }

    # ── Coverage Summary ──
    $lines += '## Coverage Summary'
    $lines += ''
    $lines += "| Metric | Value |"
    $lines += "|--------|-------|"
    $lines += "| Total Controllers | $totalControllers |"
    $lines += "| Documented | $documentedCount |"
    $lines += "| Undocumented | $undocumentedCount |"
    $lines += "| Coverage | $coveragePct% |"
    $lines += "| Layer Breakdown | L0:$($layerSummary.L0), L1:$($layerSummary.L1), L2:$($layerSummary.L2), L3:$($layerSummary.L3) |"
    $lines += ''

    $markdownContent = ($lines -join "`n")

    # g. Write atomically (tmp + rename)
    $registryPath = Join-Path $DocsRoot "doc_registry.md"
    $tmpPath = $registryPath + ".tmp"

    # Ensure DocsRoot exists
    if (-not (Test-Path $DocsRoot)) {
        New-Item -ItemType Directory $DocsRoot -Force | Out-Null
    }

    Set-Content $tmpPath -Value $markdownContent -Encoding UTF8 -NoNewline
    Move-Item $tmpPath $registryPath -Force

    return @{
        TotalControllers = $totalControllers
        Documented       = $documentedCount
        Undocumented     = $undocumentedCount
        CoveragePct      = $coveragePct
        LayerSummary     = $layerSummary
        DocPath          = $registryPath.Replace('\', '/')
    }
}

function Add-ChangeLogEntry {
    <#
    .SYNOPSIS
        Append an entry to .doc-changes.log.
    .PARAMETER ChangeLogPath
        Path to the .doc-changes.log file.
    .PARAMETER Action
        One of: ADD, UPDATE, DELETE.
    .PARAMETER DocPath
        Path to the document being changed.
    .PARAMETER Details
        Description of the change.
    .PARAMETER ParentDoc
        Optional parent document reference.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ChangeLogPath,
        [Parameter(Mandatory)]
        [ValidateSet('ADD', 'UPDATE', 'DELETE')]
        [string]$Action,
        [Parameter(Mandatory)]
        [string]$DocPath,
        [Parameter(Mandatory)]
        [string]$Details,
        [string]$ParentDoc
    )

    $parentRef = if ($ParentDoc) { "PARENT:$ParentDoc" } else { '' }
    $date = Get-Date -Format 'yyyy-MM-dd'
    $line = "$Action|$DocPath|$parentRef|$Details|$date"

    # Ensure parent directory exists
    $dir = [System.IO.Path]::GetDirectoryName($ChangeLogPath)
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory $dir -Force | Out-Null
    }

    Add-Content $ChangeLogPath -Value $line -Encoding UTF8
}

function Read-ChangeLog {
    <#
    .SYNOPSIS
        Parse .doc-changes.log into structured entries.
    .PARAMETER ChangeLogPath
        Path to the .doc-changes.log file.
    .OUTPUTS
        Array of hashtables: Action, DocPath, Parent, Details, Date
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ChangeLogPath
    )

    if (-not (Test-Path $ChangeLogPath)) { return @() }

    $lines = Get-Content $ChangeLogPath -ErrorAction SilentlyContinue
    if (-not $lines) { return @() }

    $results = @()
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }

        $parts = $trimmed.Split('|')
        if ($parts.Count -lt 4) { continue }  # Skip malformed lines

        $parent = ''
        if ($parts.Count -ge 3 -and $parts[2] -match '^PARENT:(.+)$') {
            $parent = $Matches[1]
        }

        $results += @{
            Action  = $parts[0]
            DocPath = $parts[1]
            Parent  = $parent
            Details = if ($parts.Count -ge 4) { $parts[3] } else { '' }
            Date    = if ($parts.Count -ge 5) { $parts[4] } else { '' }
        }
    }

    return $results
}

function Clear-ChangeLog {
    <#
    .SYNOPSIS
        Clear .doc-changes.log after registry rebuild.
    .PARAMETER ChangeLogPath
        Path to the .doc-changes.log file.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ChangeLogPath
    )

    if (Test-Path $ChangeLogPath) {
        Remove-Item $ChangeLogPath -Force
    }
}

# ─────────────────────────────────────────────
# Export all public functions
# ─────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Get-ControllerList'
    'Get-WorkflowDocs'
    'Build-DocRegistry'
    'Add-ChangeLogEntry'
    'Read-ChangeLog'
    'Clear-ChangeLog'
)
